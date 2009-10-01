#!/usr/bin/env ruby

require File.dirname(__FILE__) + "/../../config/environment"

Signal.trap("TERM") { exit }

RAILS_DEFAULT_LOGGER.info("BackgroundFu: Starting daemon (bonus features #{Job.included_modules.include?(Job::BonusFeatures) ? "enabled" : "disabled"}).")

BackgroundFu::CONFIG.each do |k,v| 
  RAILS_DEFAULT_LOGGER.info "BackgroundFu: #{k}: #{v.inspect}"
end

Job.cleanup_finished_jobs if BackgroundFu::CONFIG['cleanup_interval'] == :at_start

Job.update_scheduled_jobs BackgroundFu::CONFIG['schedule']

loop do
  if job = Job.find(:first, :conditions => ["state='pending' and start_at <= ?", Time.zone ? Time.zone.now.to_s(:db) : Time.now], :order => "priority desc, start_at asc")
    job.get_done!
  else
    RAILS_DEFAULT_LOGGER.info("BackgroundFu: Waiting for jobs...")
    sleep BackgroundFu::CONFIG['monitor_interval']
  end
  Job.cleanup_finished_jobs if BackgroundFu::CONFIG['cleanup_interval'] == :continuous
end
