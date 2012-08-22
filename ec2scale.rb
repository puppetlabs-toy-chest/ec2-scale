require 'rubygems'

require 'erb'
require 'facter'
require 'fog'
require 'tempfile'

NUM_CPUS = Facter.processorcount.to_i
NUM_INSTANCES = 64
FLAVOR = 't1.micro'
KEY = 'branan'
AMI = 'ami-02f85a6b'

PE_URL = ''
PE_FILENAME = 'puppet-enterprise-2.5.3-el-6-i386.tar.gz'
PE_DIRECTORY = 'puppet-enterprise-2.5.3-el-6-i386'

BUILD_MASTER = false

FETCH_PE_CMD = "wget #{PE_URL} -O /tmp/#{PE_FILENAME}"
UNPACK_PE_CMD = "tar xf /tmp/#{PE_FILENAME} -C /tmp"
INSTALL_PE_CMD = "/tmp/#{PE_DIRECTORY}/puppet-enterprise-installer -a /tmp/answers"

def gen_answers_files(master, private_master)
  template = ERB.new <<-EOF
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
q_puppet_enterpriseconsole_inventory_hostname=<%= private_master %>
q_puppet_enterpriseconsole_inventory_port=8140
q_puppet_enterpriseconsole_master_hostname=<%= private_master %>
q_puppet_enterpriseconsole_smtp_host=localhost
q_puppet_enterpriseconsole_smtp_password=
q_puppet_enterpriseconsole_smtp_port=25
q_puppet_enterpriseconsole_smtp_use_tls=n
q_puppet_enterpriseconsole_smtp_user_auth=n
q_puppet_enterpriseconsole_smtp_username=
q_puppet_symlinks_install=y
q_puppetagent_certname=<%= private_master.downcase %>
q_puppetagent_install=y
q_puppetagent_server=<%= private_master %>
q_puppetca_install=y
q_puppetmaster_certname=<%= master %>
q_puppetmaster_dnsaltnames=master,puppet,<%= private_master %>
q_puppetmaster_enterpriseconsole_hostname=localhost
q_puppetmaster_enterpriseconsole_port=443
q_puppetmaster_forward_facts=n
q_puppetmaster_install=y
q_vendor_packages_install=y
EOF
  File.open('./answers.master', 'w+') do |f|
    f.write(template.result(binding))
  end

  template = ERB.new <<-EOF
q_continue_or_reenter_master_hostname=c
q_fail_on_unsuccessful_master_lookup=y
q_install=y
q_puppet_cloud_install=n
q_puppet_enterpriseconsole_install=n
q_puppet_symlinks_install=y
q_puppetagent_certname=$(hostname | awk {'print tolower($_)'})
q_puppetagent_install=y
q_puppetagent_server=<%= private_master %>
q_puppetca_install=n
q_puppetmaster_install=n
q_vendor_packages_install=y
q_puppet_agent_first_run=n
EOF
  File.open('./answers.agent', 'w+') do |f|
    f.write(template.result(binding))
  end

  File.open('./autosign.conf', 'w+') do |f|
    f.write('*')
  end
end

if BUILD_MASTER
  compute = Fog::Compute.new({:provider => 'AWS'})
  master = compute.servers.create(:flavor_id => 'm1.small', :key_name => KEY, :image_id => AMI, :username => 'root')
  master.wait_for { sshable? }
  gen_answers_files(master.dns_name, master.private_dns_name)
  master.scp("./answers.master", "/tmp/answers")
  master.ssh('yum -y install java-1.7.0-openjdk')
  master.ssh(FETCH_PE_CMD)
  master.ssh(UNPACK_PE_CMD)
  master.ssh(INSTALL_PE_CMD)
  master.scp('./autosign.conf', '/etc/puppetlabs/puppet/autosign.conf')
  master.ssh('/etc/init.d/pe-httpd restart')
end


NUM_CPUS.times do |thread_id|
  Process.fork do
    instance_count = NUM_INSTANCES/NUM_CPUS
    if thread_id < (NUM_INSTANCES % NUM_CPUS)
      instance_count += 1
    end

    if instance_count == 0
      Process.exit
    end

    instances = []
    compute = Fog::Compute.new({:provider => 'AWS'})
    instance_count.times do |i|
      instances << compute.servers.create(:flavor_id => FLAVOR, :key_name => KEY, :image_id => AMI, :username => 'root')
    end

    hostsfile = Tempfile.new('ec2scale_hosts')
    begin
      instances.each do |i|
        i.wait_for { sshable? }
        hostsfile.write("#{i.dns_name}\n")
      end

      hostsfile.flush

      system("pscp -l root -h #{hostsfile.path} ./answers.agent /tmp/answers")
      system("pssh -t 0 -l root -h #{hostsfile.path} #{FETCH_PE_CMD}")
      system("pssh -t 0 -l root -h #{hostsfile.path} #{UNPACK_PE_CMD}")
      system("pssh -t 0 -l root -h #{hostsfile.path} #{INSTALL_PE_CMD}")
      system("pssh -l root -h #{hostsfile.path} 'echo \"    splay = true\" >> /etc/puppetlabs/puppet/puppet.conf'")
      system("pssh -l root -h #{hostsfile.path} service pe-puppet start")
    ensure
      hostsfile.close
      hostsfile.unlink
    end
  end
end

Process.waitall
