require 'socket'

module IsolatedServer
  class Base
    attr_reader :pid, :base, :port
    attr_accessor :params

    def initialize(options)
      @base         = options[:base] || Dir.mktmpdir("isolated", "/tmp")
      @params       = options[:params]
      @port         = options[:port]
      @allow_output = options[:allow_output]
      @parent_pid   = options[:pid]
    end

    def locate_executable(*candidates)
      output = `which #{candidates.shelljoin}`
      raise "I couldn't find any of these: #{candidates.join(',')} in $PATH" if output.chomp.empty?
      output.split("\n").first
    end

    def down!
      Process.kill("HUP", @pid)
      Process.wait
      @cx = nil
    end

    def kill!
      return unless @pid
      Process.kill("TERM", @pid)
    end

    def cleanup!
      system("rm -Rf #{base.shellescape}")
    end

    include Socket::Constants

    def grab_free_port
      self.class.get_free_port
    end

    def self.get_free_port
      while true
        candidate=9000 + rand(50_000)

        begin
          socket = Socket.new(AF_INET, SOCK_STREAM, 0)
          socket.bind(Socket.pack_sockaddr_in(candidate, '127.0.0.1'))
          socket.close
          return candidate
        rescue Exception
        end
      end
    end

    def self.exec_wait(cmd, options = {})
      allow_output = options[:allow_output] # default false
      parent_pid = options[:parent_pid] || $$

      fork do
        exec_pid = fork do
          [[$stdin, :stdin], [$stdout, :stdout], [$stderr, :stderr]].each do |file, symbol|
            if options[symbol]
              file.reopen(options[symbol])
            end
          end

          if !allow_output
            devnull = File.open("/dev/null", "w")
            STDOUT.reopen(devnull)
            STDERR.reopen(devnull)
          end

          exec(cmd)
        end

        # begin waiting for the parent (or mysql) to die; at_exit is hard to control when interacting with test/unit
        # we can also be killed by our parent with down! and up!
        #
        ["TERM", "INT"].each do |sig|
          trap(sig) do
            if block_given?
              yield(exec_pid)
            else
              Process.kill("KILL", exec_pid)
            end

            exit!
          end
        end

        # HUP == down, but don't cleanup.
        trap("HUP") do
          Process.kill("KILL", exec_pid)
          exit!
        end

        while true
          begin
            Process.kill(0, parent_pid)
            Process.kill(0, exec_pid)
          rescue Exception
            if block_given?
              yield(exec_pid)
            else
              Process.kill("KILL", exec_pid)
            end

            exit!
          end

          sleep 1
        end
      end
    end

    def exec_server(cmd)
      @pid = self.class.exec_wait(cmd, allow_output: @allow_output, parent_pid: @parent_pid) do |child_pid|
        Process.kill("KILL", child_pid)
        cleanup!
      end
    end
  end
end
