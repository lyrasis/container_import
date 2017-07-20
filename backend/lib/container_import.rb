module ContainerImport

  class Reporter
    def initialize(report_file, error_file)
      @report_file = File.open(report_file, 'w')
      @error_file  = File.open(error_file, 'w')
    end

    def finish
      @report_file.close
      @error_file.close
    end

    def complain(msg)
      @error_file.puts msg
      $stdout.puts msg
    end

    def report(msg)
      @report_file.puts msg
      $stderr.puts msg
    end
  end

end