#!/usr/bin/env ruby

require File.dirname(__FILE__) + "/../../config/environment"

# view paths need cwd to be set like this (eg used in actionmailer)
Dir.chdir RAILS_ROOT

Signal.trap("TERM") { exit }

BACKGROUND_LOGGER = BackgroundFu::BACKGROUND_LOGGER

ActiveRecord::Base.logger = BACKGROUND_LOGGER

BACKGROUND_LOGGER.info("BackgroundFu: Starting daemon (bonus features #{Job.included_modules.include?(Job::BonusFeatures) ? "enabled" : "disabled"}).")

BackgroundFu::CONFIG.each do |k,v| 
  BACKGROUND_LOGGER.info "BackgroundFu: #{k}: #{v.inspect}"
end

Job.cleanup_finished_jobs if BackgroundFu::CONFIG['cleanup_interval'] == :at_start

Job.update_scheduled_jobs BackgroundFu::CONFIG['schedule']

Job.notify_on_exception = BackgroundFu::CONFIG['notify_on_exception']

loop do
  if job = Job.find(:first, :conditions => ["state='pending' and start_at <= ?", Time.zone ? Time.zone.now.to_s(:db) : Time.now], :order => "priority desc, start_at asc")
    job.get_done!
  else
    BACKGROUND_LOGGER.info("BackgroundFu: Waiting for jobs...")
    sleep BackgroundFu::CONFIG['monitor_interval']
  end
  Job.cleanup_finished_jobs if BackgroundFu::CONFIG['cleanup_interval'] == :continuous
end
