require 'ec2scale/environment'
require 'optparse'

module Ec2scale
  module Cli
    def self.run(argv)
      args = argv.clone

      options = {}
      opts = OptionParser.new do |opts|
        opts.on("-m", "--master CONFIG", "Configuration for the master. os[,flavor]") do |m|
          parts = m.split(',')
          if parts.size > 2
            raise ArgumentError, "'#{m}' is an invalid master configuration"
          end

          parts.collect! { |p| p.chomp }

          options[:master] = {}            
          options[:master][:type] = parts[0]
          if parts.count == 2
            options[:master][:flavor] = parts[1]
          end
        end

        opts.on("-a", "--agents CONFIG", "Configuration for agents. os,count[,flavor]") do |a|
          parts = a.split(',')
          if parts.size < 2 or parts.size > 3
            raise ArgumentError, "'#{a}' is an invalid agent configuration"
          end
          parts.collect! { |p| p.chomp }

          options[:agents] ||= []
          agent = {}
          agent[:count] = parts[1].to_i
          agent[:type] = parts[0]
          if parts.size == 3
            agent[:flavor] = parts[2]
          end
          options[:agents] << agent
        end

        opts.on("-k", "--keypair KEYPAIR", "The EC2 keypair to use. Must already be created") do |k|
          options[:keypair] = k
        end

        opts.on("-u", "--pe-url URL", "The URL from which the puppet enterprise installer is accessible") do |u|
          options[:pe_url] = u
        end

        opts.on("-e", "--environment ENV", "The environment directory. Must already exist.") do |e|
          options[:envdir] = e
        end
      end
      opts.parse!(args)

      if args.size > 1
        raise ArgumentError, "Only one action is allowed"
      elsif args.size == 1
        command = args[0]
      else
        command = 'create'
      end

      if not ['create', 'destroy'].include? command
        raise ArgumentError, "'#{command}' is an invalid action"
      end
   
      env = Ec2scale::Environment.new(options)
      if command == 'create'
        env.spinup
      else
        env.teardown
      end
    end
  end
end
