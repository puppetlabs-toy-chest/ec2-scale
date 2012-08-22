require 'rubygems'

require 'erb'
require 'facter'
require 'fog'
require 'tempfile'

module Ec2scale

  # These are the rightscale AMIs.They work, but we should get our own
  # at some point.
  AMIS = {
    'centos6_32' => 'ami-02f85a6b',
    'centos6_64' => 'ami-fa3f9c93',
  }

  MASTER_ANSWERS = %Q[
q_install=y
q_puppet_cloud_install=n
q_puppet_enterpriseconsole_auth_database_name=console_auth
q_puppet_enterpriseconsole_auth_database_password=lTWDqbK4IAWxYRQaugme
q_puppet_enterpriseconsole_auth_database_user=console_auth
q_puppet_enterpriseconsole_auth_password=password
q_puppet_enterpriseconsole_auth_user_email=admin@example.com
q_puppet_enterpriseconsole_database_install=y
q_puppet_enterpriseconsole_database_name=console
q_puppet_enterpriseconsole_database_password=9LyyE70GcYcdXvQiT2lD
q_puppet_enterpriseconsole_database_remote=n
q_puppet_enterpriseconsole_database_root_password=rdm1szgvWLtZzKRZWdv0
q_puppet_enterpriseconsole_database_user=console
q_puppet_enterpriseconsole_httpd_port=443
q_puppet_enterpriseconsole_install=y
q_puppet_enterpriseconsole_inventory_hostname=<%= internal %>
q_puppet_enterpriseconsole_inventory_port=8140
q_puppet_enterpriseconsole_master_hostname=<%= internal %>
q_puppet_enterpriseconsole_smtp_host=localhost
q_puppet_enterpriseconsole_smtp_password=
q_puppet_enterpriseconsole_smtp_port=25
q_puppet_enterpriseconsole_smtp_use_tls=n
q_puppet_enterpriseconsole_smtp_user_auth=n
q_puppet_enterpriseconsole_smtp_username=
q_puppet_symlinks_install=y
q_puppetagent_certname=$(hostname | awk {'print tolower($_)'})
q_puppetagent_install=y
q_puppetagent_server=<%= internal %>
q_puppetca_install=y
q_puppetmaster_certname=$(hostname | awk {'print tolower($_)'})
q_puppetmaster_dnsaltnames=master,puppet,<%= internal %>
q_puppetmaster_enterpriseconsole_hostname=localhost
q_puppetmaster_enterpriseconsole_port=443
q_puppetmaster_forward_facts=n
q_puppetmaster_install=y
q_vendor_packages_install=y
]

  AGENT_ANSWERS = %Q[
q_continue_or_reenter_master_hostname=c
q_fail_on_unsuccessful_master_lookup=y
q_install=y
q_puppet_cloud_install=n
q_puppet_enterpriseconsole_install=n
q_puppet_symlinks_install=y
q_puppetagent_certname=$(hostname | awk {'print tolower($_)'})
q_puppetagent_install=y
q_puppetagent_server=<%= internal %>
q_puppetca_install=n
q_puppetmaster_install=n
q_vendor_packages_install=y
q_puppet_agent_first_run=n
]

  class Environment
    @environment = {}

    def pe_url
      return @config[:pe_url] || @environment[:pe_url]
    end

    def pe_filename
      pe_url.split('/')[-1]
    end

    def pe_directory
      # need to do this twice.. .tar.gz rather than .tgz
      tmp = File.basename(pe_filename, File.extname(pe_filename))
      File.basename(tmp, File.extname(tmp))
    end

    def envfile
      File.join(@config[:envdir] || Dir.pwd, "ec2scale.yml")
    end

    def envdir
      File.join(@config[:envdir] || Dir.pwd, "ec2scale")
    end

    def keypair
      @config[:keypair] || @environment[:keypair] || nil
    end

    def fetch_pe_cmd
      "wget #{pe_url} -O /tmp/#{pe_filename}"
    end

    def unpack_pe_cmd
      "tar xf /tmp/#{pe_filename} -C /tmp"
    end

    def install_pe_cmd
      "/tmp/#{pe_directory}/puppet-enterprise-installer -a /tmp/answers"
    end

    def initialize(config)
      @config = config.clone
      @cpus = Facter.processorcount.to_i
      load_or_create_environment
    end

    def spinup
      build_master if @config[:master]
      build_agents
      save_environment
    end

    def teardown
      destroy_agents
      destroy_master
      del_environment
    end

    def load_or_create_environment
      if File.exists? envfile
        @environment = YAML.load_file(envfile)

        if @environment[:master] and @config[:master]
          raise ArgumentError, "Cannot respecify master. Please create a new environment"
        end
      else
        @environment = {
          :keypair => @config[:keypair],
          :pe_url  => @config[:pe_url],
          :agents  => [],
        }

        FileUtils.mkdir_p(envdir)

        if not @config[:master]
          raise ArgumentError, "Must specify a master when creating a new environment"
        end
      end
    end

    def save_environment
      File.open(envfile, 'w+') { |f| YAML.dump(@environment, f) }
    end

    def gen_config_files(internal)
      template = ERB.new(MASTER_ANSWERS)
      File.open("#{envdir}/answers.master", 'w+') do |f|
        f.write(template.result(binding))
      end

      template = ERB.new(AGENT_ANSWERS)
      File.open("#{envdir}/answers.agent", 'w+') do |f|
        f.write(template.result(binding))
      end

      File.open("#{envdir}/autosign.conf", 'w+') do |f|
        f.write("*\n")
      end
    end

    def build_master
      ami = AMIS[@config[:master][:type]]
      flavor = @config[:master][:flavor] || 'm1.small'
      
      compute = Fog::Compute.new({:provider => 'AWS'})
      master = compute.servers.create(:flavor_id => flavor, :key_name => keypair, :image_id => ami, :username => 'root')
      master.wait_for { sshable? }
      gen_config_files(master.private_dns_name)
      master.scp("#{envdir}/answers.master", "/tmp/answers")
      master.ssh('yum -y install java-1.7.0-openjdk') # HACK for centos6
      master.ssh(fetch_pe_cmd)
      master.ssh(unpack_pe_cmd)
      master.ssh(install_pe_cmd)
      master.scp("#{envdir}/autosign.conf", '/etc/puppetlabs/puppet/autosign.conf')
      master.ssh('service pe-httpd restart')

      @environment[:master] = {
        :id => master.id,
        :dns => master.dns_name,
      }
    end

    def build_agents
      # Create temporary files for each process to write its yaml fragment to
      environment_fragments = []
      @cpus.times do 
        file = Tempfile.new('ec2scale')
        environment_fragments << file.path
        file.close
      end

      # expand the type,count schema into a flat list of AMIs
      hosts = []
      @config[:agents].each do |agent|
        agent[:count].times do
          hosts << {
            :ami => AMIS[agent[:type]],
            :flavor => agent[:flavor] || 't1.micro',
          }
        end
      end

      @cpus.times do |tid|
        Process.fork do
          count = hosts.size / @cpus
          start = count * tid
          if tid < ( hosts.size % @cpus)
            count += 1
            start += tid
          else
            start += (hosts.size % @cpus)
          end
          
          if count == 0
            Process.exit
          end

          instances = []
          compute = Fog::Compute.new({:provider => 'AWS'})
          count.times do |i|
            h = hosts[start+i]
            instances << compute.servers.create(:flavor_id => h[:flavor], :key_name => keypair, :image_id => h[:ami], :username => 'root')
          end

          environment = []
          hostsfile = Tempfile.new('ec2scale_hosts')
          begin
            instances.each do |i|
              i.wait_for { sshable? }
              hostsfile.write("#{i.dns_name}\n")
              environment << {
                :id => i.id,
                :dns => i.dns_name,
              }
            end

            hostsfile.flush

            system("pscp -l root -h #{hostsfile.path} #{envdir}/answers.agent /tmp/answers")
            system("pssh -t 0 -l root -h #{hostsfile.path} #{fetch_pe_cmd}")
            system("pssh -t 0 -l root -h #{hostsfile.path} #{unpack_pe_cmd}")
            system("pssh -t 0 -l root -h #{hostsfile.path} #{install_pe_cmd}")
            system("pssh -l root -h #{hostsfile.path} 'echo \"    splay = true\" >> /etc/puppetlabs/puppet/puppet.conf'")
            system("pssh -l root -h #{hostsfile.path} service pe-puppet start")
          ensure
            hostsfile.close
            hostsfile.unlink
          end

          # output the environment fragment
          File.open(environment_fragments[tid], 'w') { |f| YAML.dump(environment, f) }
        end
      end

      Process.waitall

      environment_fragments.each do |frag|
        @environment[:agents].concat(YAML.load_file(frag))
      end
    end
  end
end
