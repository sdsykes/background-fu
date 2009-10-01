module Job::Cron

  COLUMNS = [:secs, :mins, :hours, :days, :months, :wdays]
  # weekday 0 is Sunday
  RANGES = { :secs => 0..59, :mins => 0..59, :hours => 0..23, :days => 1..31, :months => 1..12, :wdays => 0..6 }

  class << self

    # parses given cron tab string and returns next time corresponding to given
    def find_next_time(time, str)
      h = parse(str)
      next_time(time, h)
    end
    
    # parses given cron tab string and returns cron hash
    def parse(str)
      column_strings = str.split(" ")
      size = column_strings.size
      raise ArgumentError, "wrong number of columns (#{size} for #{COLUMNS.size})" if size != COLUMNS.size
      result = { }
      COLUMNS.each_with_index { |c, i| result[c] = column_parse(column_strings[i], RANGES[c]) }
      result
    end

    protected

    # parses single column of cron tab string and returns array of numbers
    def column_parse(str, range)
      result = []
      str.split(",").each do |part|
        case part
        when /\A(\d+)(?:\/(\d+))?\z/
          # number or number with step
          [$1, $2].each { |s| check_range(s, range) }
          result += $2 ? with_step(Range.new($1.to_i, range.last), $2.to_i) : [$1.to_i]
        when /\A(\d+)-(\d+)(?:\/(\d+))?\z/
          # range or range with step
          [$1, $2, $3].each { |s| check_range(s, range) }
          r = Range.new($1.to_i, $2.to_i)
          result += $3 ? with_step(r, $3.to_i) : r.to_a
        when /\A\*(?:\/(\d+))?\z/
          # asterisk or asterisk with step
          check_range($1, range)
          result += $1 ? with_step(range, $1.to_i) : range.to_a
        else
          raise ArgumentError, "unable to parse #{part}"
        end
      end
      result.uniq.sort
    end

    # returns array of numbers from given range with step
    def with_step(range, step)
      result = []
      range.to_a.each_with_index { |x, i| result << x if (i % step) == 0 }
      result
    end

    # checks range of given number (or string) and raises error if doesn't fit
    def check_range(str, range)
      raise RangeError, "#{str} is out of range" unless str.nil? or range.include? str.to_i
    end

    # returns next time calculated from given time and cron hash
    def next_time(time, h)
      sec, min, hour = nil
      if date_match?(time, h)
        if h[:hours].include?(time.hour)
          if h[:mins].include?(time.min)
            if sec = h[:secs].detect{|i| i > time.sec} # next second in this minute
              min = time.min
              hour = time.hour
            else # no next second, go to next minute
              if min = h[:mins].detect{|i| i > time.min}
                hour = time.hour
              else # no next minute, go to next hour
                if hour = h[:hours].detect{|i| i > time.hour}
                else # no next hour, go to future day
                  time = time.advance(:days=>1) until date_match?(time, h)
                end
              end
            end
          else # not this minute, find next
            if min = h[:mins].detect{|i| i > time.min}
              hour = time.hour
            else # no next minute, go to next hour
              if hour = h[:hours].detect{|i| i > time.hour}
              else # no next hour, go to future day
                time = time.advance(:days=>1) until date_match?(time, h)
              end
            end
          end
        else # not this hour, find next
          if hour = h[:hours].detect{|i| i > time.hour}
          else # no next hour, go to future day
            time = time.advance(:days=>1) until date_match?(time, h)
          end
        end
      else
        time = time.advance(:days => 1) until date_match?(time, h)
      end
      return time.change(:hour => hour || h[:hours].first, :min => min || h[:mins].first, :sec => sec || h[:secs].first)
    end

    # returns true if given date (day, month and week day) is included in given cron hash
    def date_match?(date, h)
      h[:months].include?(date.month) and h[:days].include?(date.day) and h[:wdays].include?(date.wday)
    end

  end

end
