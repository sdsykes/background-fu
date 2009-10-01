# Example:
# 
# job = Job.enqueue!(MyWorker, :my_method, "my_arg_1", "my_arg_2")
class Job < ActiveRecord::Base

  cattr_accessor :states, :run_methods
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

    logger.info("BackgroundFu: Job enqueued. Job(id: #{job.id}, worker: #{worker_class}, method: #{worker_method}, argc: #{args.size}).")
    
    job
  end

  # Invoked by a background daemon.
  def get_done!
    initialize_worker
    case run_method
    when "normal"
      instantiate_and_invoke
    when "thread"
      Thread.new {instantiate_and_invoke}
    when "process"
      logger.info "RAILS_ENV=#{Rails.env} #{RAILS_ROOT + "/script/runner"} 'Job.find_by_id(#{id}).instantiate_and_invoke'"
    end
  end

  def instantiate_and_invoke
    @worker = worker_class.constantize.new
    invoke_worker
  rescue Exception => e
    rescue_worker(e)
  ensure
    ensure_worker
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
      logger.info("BackgroundFu: Job restarted. Job(id: #{id}).")
    end
  end
  
  def initialize_worker
    update_attributes!(:started_at => Time.now, :state => "running")
    logger.info("BackgroundFu: Job initialized. Job(id: #{id}).")
  end
  
  def invoke_worker
    self.result = @worker.send(worker_method, *args)
    self.state  = "finished"
    logger.info("BackgroundFu: Job finished. Job(id: #{id}).")
  end
  
  def rescue_worker(exception)
    self.result = [exception.message, exception.backtrace.join("\n")].join("\n\n")
    self.state  = "failed"
    logger.info("BackgroundFu: Job failed. Job(id: #{id}).")
  end
  
  def ensure_worker
    self.progress = @worker.instance_variable_get("@progress")
    schedule unless crontab.blank? || state == "failed"
    save!
  rescue StaleObjectError
    # Ignore this exception as its only purpose is
    # not allowing multiple daemons execute the same job.
    logger.info("BackgroundFu: Race condition handled (It's OK). Job(id: #{id}).")
  end

  def schedule
    self.state = self.start_at = nil
    setup_state
    setup_start_at
  end

  # Delete finished jobs that are more than a week old.
  def self.cleanup_finished_jobs
    logger.info "BackgroundFu: Cleaning up finished jobs."
    Job.destroy_all(["state='finished' and updated_at < ?", 1.week.ago])
  end
  
  def self.update_scheduled_jobs(jobs)
    return unless jobs
    jobs.each do |sjob_class, sjobs|
      sjobs.each do |sjob_method, params|
        run_method = params.split.last
        run_method = "normal" unless run_methods.include? run_method
        crontab = params.split[0..5].join(" ")
        js = find(:first, :conditions=>["worker_class=? AND worker_method=? AND crontab IS NOT NULL", sjob_class.camelize, sjob_method])
        if js
          js.crontab = crontab
          js.run_method = run_method
          js.schedule
          js.save
        else
          js = create(
            :worker_class=>sjob_class.camelize,
            :worker_method=>sjob_method,
            :crontab=>crontab,
            :run_method=>run_method
          )
          Rails.logger.info js.errors.inspect
        end
      end
    end
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
