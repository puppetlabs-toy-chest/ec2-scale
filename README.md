# ec2scale: a tool for creating large clouds quickly

### Usage

* Create a cloud with a 64-bit master and some 32-bit agents
  `ec2scale create -m centos6_64,m1.large -a centos6_32,32 -k my_ec2_keypair -e /path/to/environment/dir -u http://example.com/pe/puppet-enterprise-2.5.3.tar.gz`

* Add some 64-bit agents and increase the number of 32-bit agents to the same cloud
  `ec2scale create -a centos6_32,16 -a centos6_64,48 -e /path/to/environment/dir`

* Destroy the cloud
  `ec2scale destroy -e /path/to/environment/dir`
