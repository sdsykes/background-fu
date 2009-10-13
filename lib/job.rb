# Example:
# 
# job = Job.enqueue!(MyWorker, :my_method, "my_arg_1", "my_arg_2")

class Job < ActiveRecord::Base
  BACKGROUND_LOGGER = BackgroundFu::BACKGROUND_LOGGER
  cattr_accessor :states, :run_methods, :notify_on_exception
  self.states = %w(pending running finished failed)
  self.run_methods = %w(normal thread process)

  serialize :args, Array
  serialize :result

  before_create :setup_state, :setup_priority, :setup_start_at
  validates_presence_of :worker_class, :worker_method

  attr_readonly :worker_class, :worker_method, :args

  def validate
    validate_crontab unless crontab.blank?
  end

  def validate_crontab
    Cron.parse(crontab)
  rescue ArgumentError, RangeError => e
    errors.add :crontab, e.to_s
  end

  def inspect
    "Job(id: #{id}, worker: #{worker_class}, method: #{worker_method})"
  end

  def self.enqueue!(worker_class, worker_method, *args)
    if run_methods.include?(args[0].to_s)
      run_method = args[0].to_s
      args.shift
    else
      run_method = "normal"
    end
    job = create!(
      :worker_class => worker_class.to_s,
      :worker_method => worker_method.to_s,
      :run_method => run_method,
      :args => args
    )

    BACKGROUND_LOGGER.info("BackgroundFu: Job enqueued. #{job.inspect}, argc: #{args.size}).")
  
    job
  end

  # Invoked by a background daemon.
  def get_done!
    @last_run_time = started_at
    return unless initialize_worker
    case run_method
    when "normal"
      checkin_connections
      instantiate_and_invoke
    when "thread"
      Thread.new {instantiate_and_invoke}
    when "process"
      script = "Job.find_by_id(#{id}).run(\"#{@last_run_time}\", #{Job.notify_on_exception})"
      pid = fork do
        %x{RAILS_ENV=#{Rails.env} #{RAILS_ROOT + "/script/runner"} '#{script}'}
        exit!
      end
      Process.detach pid
    end
  end

  # called by script/runner
  def run(last_run_time_str, notify_on_exception)
    @last_run_time = Time.parse(last_run_time_str)
    Job.notify_on_exception = notify_on_exception
    instantiate_and_invoke
  end

  # do not use verify_active_connections! - it's not thread safe
  def checkin_connections
    ActiveRecord::Base.clear_active_connections!
  end

  def instantiate_and_invoke
    @worker = worker_class.constantize.new
    setup_worker
    invoke_worker
  rescue Exception => e
    rescue_worker(e)
  ensure
    ensure_worker
  end

  def setup_worker
    @worker.instance_variable_set(:@last_run_time, @last_run_time)
    set_worker_iv_if_nil(:@logger, BACKGROUND_LOGGER)
    set_worker_iv_if_nil(:@notify_on_exception, Job.notify_on_exception)
  end

  def set_worker_iv_if_nil(name, value)
    if @worker.instance_variable_get(name).nil?
      @worker.instance_variable_set(name, value)
    end
  end

  # Restart a failed job.
  def restart!
    if failed? 
      update_attributes!(
        :result     => nil, 
        :progress   => nil, 
        :started_at => nil, 
        :state      => "pending"
      )
      BACKGROUND_LOGGER.info("BackgroundFu: Job restarted. #{inspect}.")
    end
  end

  def initialize_worker
    update_attributes!(:started_at => Time.now, :state => "running")
    BACKGROUND_LOGGER.info("BackgroundFu: Job initialized. #{inspect}.")
    true
  rescue ActiveRecord::StaleObjectError=>exception
    BACKGROUND_LOGGER.info("BackgroundFu: Race condition in initialize (will try again later). #{inspect}.")
    false
  end

  def invoke_worker
    if !args || args.size == 0
      self.result = @worker.send(worker_method)
    else
      self.result = @worker.send(worker_method, *args)
    end
    self.state  = "finished"
    BACKGROUND_LOGGER.info("BackgroundFu: Job finished. #{inspect}.")
  end

  def rescue_worker(exception)
    self.result = [exception.message, exception.backtrace.join("\n")].join("\n\n")
    self.state  = "failed"
    BACKGROUND_LOGGER.info("BackgroundFu: Job failed. #{inspect}.")
    notify_exception(exception) if @worker.instance_variable_get(:@notify_on_exception)
  end

  def notify_exception(exception)
    BackgroundFu::ExceptionMailer.deliver_exception_email(exception, self)
  end

  def ensure_worker
    self.progress = @worker.instance_variable_get("@progress")
    schedule unless crontab.blank? || state == "failed"
    save!
  rescue ActiveRecord::StaleObjectError=>exception
    BACKGROUND_LOGGER.info("BackgroundFu: Race condition in ensure worker (retrying). #{inspect}.")
    self.lock_version = Job.find(id).lock_version  # retry, we must save to ensure job is rescheduled
    retry
  rescue Exception=>exception
    # we need to know if rescheduling or saving the job failed in any way
    notify_exception(exception) if @worker.instance_variable_get(:@notify_on_exception)    
  ensure
    checkin_connections if run_method == "thread"
  end

  def schedule
    self.state = self.start_at = nil
    setup_state
    setup_start_at
  end

  # Delete finished jobs that are more than a week old.
  def self.cleanup_finished_jobs
    BACKGROUND_LOGGER.info "BackgroundFu: Cleaning up finished jobs."
    Job.destroy_all(["state='finished' and updated_at < ?", 1.week.ago])
  end

  def self.update_scheduled_jobs(jobs)
    seen_ids = []
    jobs && jobs.each do |sjob_class, sjobs|
      sjobs && sjobs.each do |sjob_method, params|
        run_method = params.split.last
        run_method = "normal" unless run_methods.include? run_method
        crontab = params.split[0..5].join(" ")
        js = find(:first, :conditions=>["worker_class=? AND worker_method=? AND crontab IS NOT NULL", sjob_class.camelize, sjob_method])
        if js
          js.crontab, js.run_method = crontab, run_method
          js.schedule
          js.save
        else
          js = create(
            :worker_class=>sjob_class.camelize,
            :worker_method=>sjob_method,
            :crontab=>crontab,
            :run_method=>run_method
          )
        end
        seen_ids << js.id
      end
    end
    remove_jobs_not_in_list(seen_ids)
  end

  def self.remove_jobs_not_in_list(id_list)
    jobs = find(:all, :conditions=>"crontab IS NOT NULL")
    jobs.each {|j| j.destroy unless id_list.include?(j.id)}
  end

  def self.generate_state_helpers
    states.each do |state_name|
      define_method("#{state_name}?") do
        state == state_name
      end

      # Job.running => array of running jobs, etc.
      self.class.send(:define_method, state_name) do
        find_all_by_state(state_name, :order => "id desc")
      end
    end
  end
  generate_state_helpers

  def setup_state
    return unless state.blank?

    self.state = "pending" 
  end

  # Default priority is 0. Jobs will be executed in descending priority order (negative priorities allowed).
  def setup_priority
    return unless priority.blank?
  
    self.priority = 0
  end

  # Job will be executed after this timestamp.
  def setup_start_at
    return unless start_at.blank?
  
    if crontab.blank?
      self.start_at = Time.now
    else
      self.start_at = Cron.find_next_time(Time.now, crontab)
    end
  end

end  
