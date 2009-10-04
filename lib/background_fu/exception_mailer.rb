module BackgroundFu
  class ExceptionMailer < ActionMailer::Base
    @@sender_address = %{"BackgroundFu Exception Notifier" <backgroundfu_exceptions@default.com>}
    cattr_accessor :sender_address

    @@exception_recipients = []
    cattr_accessor :exception_recipients

    @@email_prefix = "[ERROR] "
    cattr_accessor :email_prefix

    self.template_root = "#{File.dirname(__FILE__)}/../../views"

    def self.reloadable?; false; end

    def exception_email(exception, job)
      content_type "text/plain"

      subject    "#{email_prefix}#{job.worker_class}##{job.worker_method} (#{exception.class}) #{exception.message.inspect}"

      recipients exception_recipients
      from       sender_address

      body(
        :exception=>exception,
        :job=>job,
        :backtrace=>sanitize_backtrace(exception.backtrace), 
        :rails_root=>rails_root
      )
    end

    private

    def sanitize_backtrace(trace)
      re = Regexp.new(/^#{Regexp.escape(rails_root)}/)
      trace.map { |line| Pathname.new(line.gsub(re, "[RAILS_ROOT]")).cleanpath.to_s }
    end

    def rails_root
      @rails_root ||= Pathname.new(RAILS_ROOT).cleanpath.to_s
    end    
  end
end
