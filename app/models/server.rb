# Amahi Home Server
# Copyright (C) 2007-2010 Amahi
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License v3
# (29 June 2007), as published in the COPYING file.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# file COPYING for more details.
# 
# You should have received a copy of the GNU General Public
# License along with this program; if not, write to the Amahi
# team at http://www.amahi.org/ under "Contact Us."

require 'tempfile'
require 'platform'

class Server < ActiveRecord::Base

	# CAUTION - this class *assumes* new servers are created
	# started and enabled at boot time as services!

	PID_PATH = "/var/run"

	validates_uniqueness_of :name
	validates_presence_of :name

	before_save  :before_save_hook
	after_create  :create_hook
	after_destroy  :destroy_hook

	attr_accessible :name, :pidfile, :comment

	def self.create_default_servers
		Server.create(:name => 'apache', :pidfile => Platform.file_name(:apache_pid), :comment => I18n.t('apache_web_server'))
		Server.create(:name => 'named', :pidfile => 'named/named.pid', :comment => I18n.t('dns_server'))
		Server.create(:name => 'dhcp', :pidfile => Platform.file_name(:dhcpd_pid), :comment => I18n.t('dhcp_server'))
		Server.create(:name => 'mysql', :pidfile => 'mysqld/mysqld.pid', :comment => I18n.t('mysql_database_server'))
		Server.create(:name => 'smb', :pidfile => Platform.file_name(:samba_pid), :comment => I18n.t('file_server_samba'))
		Server.create(:name => 'hdactl', :comment => I18n.t('amahi_dyndns_updater'))
		Server.create(:name => 'greyhole', :comment => 'Greyhole')
		r = "# WARNING - This file was automatically generated on #{Time.now}\n" \
			"\nset daemon 30\n" \
			"include #{Platform.file_name(:monit_dir)}/logging\n" \
			"include #{Platform.file_name(:monit_dir)}/*.conf\n"
		fname = "/tmp/server-conf-%d.%d" % [$$, rand(9999)]
		f = File.new fname, "w"
		f.write r
		c = Command.new("cp -f \"#{f.path}\" #{Platform.file_name(:monit_conf)}")
		c.submit("rm -f \"#{f.path}\"")
		c.submit("chmod 644 #{Platform.file_name(:monit_log)}")
		c.submit Platform.watchdog_restart_command
		c.execute
		f.close
	end

	def pids
		estimate_pids
	end

	def do_start
		c = Command.new start_cmd
		c.execute
	end

	def do_stop
		c = Command.new stop_cmd
		c.execute
	end

	def do_restart
		c = Command.new stop_cmd
		c.submit start_cmd
		c.execute
	end

protected

	def pid_file
		tmp = self.pidfile || (self.name + ".pid")
		(tmp =~ /^\//) ? tmp : File.join(PID_PATH, tmp)
	end

	def start_cmd
		Platform.service_start_command(name)
	end

	def stop_cmd
		Platform.service_stop_command(name)
	end

	def destroy_hook
		c = Command.new("rm -f #{File.join(Platform.file_name(:monit_dir), Platform.service_name(name))}.conf")
		c.submit Platform.watchdog_restart_command
		c.submit stop_cmd
		c.execute
	end

	def cmd_file
		"# WARNING - This file was automatically generated on #{Time.now}\n" \
		"check process #{self.name} with pidfile #{self.pid_file}\n"	\
        	"\tstart program = \"#{self.start_cmd}\"\n"			\
        	"\tstop  program = \"#{self.stop_cmd}\"\n"
	end

	def monit_file_add
		fname = "/tmp/server-#{self.name}-%d.%d" % [$$, rand(9999)]
		open(fname, "w") { |f| f.write cmd_file }
		c = Command.new "cp -f \"#{fname}\" #{File.join(Platform.file_name(:monit_dir), Platform.service_name(self.name))}.conf"
		c.submit "rm -f \"#{fname}\""
		c.submit Platform.watchdog_restart_command
		c.execute
	end

	def monit_file_remove
		c = Command.new("rm -f #{File.join(Platform.file_name(:monit_dir), Platform.service_name(name))}.conf")
		# FIXME - this conrestart does not help on ubuntu, as there is no such thing
		c.submit Platform.watchdog_restart_command
		c.execute
	end

	def service_on
		c = Command.new "chkconfig #{Platform.service_name name} on"
		# new
		# c = Command.new "systemctl enable #{Platform.service_name name}.service"
		c.execute
	end

	def service_off
		c = Command.new "chkconfig #{Platform.service_name name} off"
		# new
		# c = Command.new "systemctl disable #{Platform.service_name name}.service"
		c.execute
	end

	def before_save_hook
		if monitored_changed?
			monitored ? monit_file_add : monit_file_remove
			# DEBUG RAILS_DEFAULT_LOGGER.info "* * * MONITORED CHANGED to #{monitored}"
		end
		if start_at_boot_changed?
			start_at_boot ? service_on : service_off
			# DEBUG RAILS_DEFAULT_LOGGER.info "* * * START_AT_BOOT CHANGED to #{start_at_boot}"
		end
	end

	def create_hook
		monit_file_add
	end

	# estimate the status of the PIDs
	def estimate_pids
		pf = pid_file
		ret = []
		begin
			# check if the pid file is there
			if File.exists?(pf) && File.readable?(pf)
				# check the pid file and check for the process existance
				open(pf) do |p|
					list = p.readlines.map{ |line| line.gsub(/\n/, '').split(' ') }.flatten
					ret = list.map{|pid| File.exists?("/proc/#{pid}") ? pid : nil }.compact
				end
			end
		rescue
			# something went wrong
		end
		return ret unless ret.empty?

		# use pgrep instead - fails in many cases, but
		# it's *some fallback*
		begin
			IO.popen("pgrep #{Platform.service_name name}") do |p|
				ret = p.readlines.map {|pid| pid.gsub(/\n/, '')}
			end
			return ret unless ret.empty?
			# third fallback -- wtf??
			IO.popen("pgrep #{name}") do |p|
				ret = p.readlines.map {|pid| pid.gsub(/\n/, '')}
			end
		rescue
			[]
		end
		ret
	end

end
