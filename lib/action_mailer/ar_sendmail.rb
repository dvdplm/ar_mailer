require 'optparse'
require 'net/smtp'
require 'smtp_tls' unless Net::SMTP.instance_methods.include?("enable_starttls_auto")
require 'rubygems'

##
# Hack in RSET

module Net # :nodoc:
class SMTP # :nodoc:

  unless instance_methods.include? 'reset' then
    ##
    # Resets the SMTP connection.

    def reset
      getok 'RSET'
    end
  end

end
end

module ActionMailer; end # :nodoc:

##
# ActionMailer::ARSendmail delivers email from the email table to the
# SMTP server configured in your application's config/environment.rb.
# ar_sendmail does not work with sendmail delivery.
#
# ar_mailer can deliver to SMTP with TLS using smtp_tls.rb borrowed from Kyle
# Maxwell's action_mailer_optional_tls plugin.  Simply set the :tls option in
# ActionMailer::Base's smtp_settings to true to enable TLS.
#
# See ar_sendmail -h for the full list of supported options.
#
# The interesting options are:
# * --daemon
# * --mailq
# * --create-migration
# * --create-model
# * --table-name

class ActionMailer::ARSendmail

  ##
  # The version of ActionMailer::ARSendmail you are running.

  VERSION = '2.1'

  ##
  # Maximum number of times authentication will be consecutively retried

  MAX_AUTH_FAILURES = 2

  ##
  # Email delivery attempts per run

  attr_accessor :batch_size

  ##
  # Seconds to delay between runs

  attr_accessor :delay

  ##
  # Maximum age of emails in seconds before they are removed from the queue.

  attr_accessor :max_age

  ##
  # Be verbose

  attr_accessor :verbose
 
  ##
  # ActiveRecord class that holds emails

  attr_reader :email_class

  ##
  # True if only one delivery attempt will be made per call to run

  attr_reader :once

  ##
  # Times authentication has failed

  attr_accessor :failed_auth_count

  @@pid_file = nil

  def self.remove_pid_file
    if @@pid_file
      require 'shell'
      sh = Shell.new
      sh.rm @@pid_file
    end
  end

  ##
  # Creates a new migration using +table_name+ and prints it on stdout.

  def self.create_migration(table_name)
    require 'active_support'
    puts <<-EOF
class Create#{table_name.classify} < ActiveRecord::Migration
  def self.up
    create_table :#{table_name.tableize} do |t|
      t.column :to, :string
      t.column :from, :string
      t.column :mail, :text
      t.column :last_send_attempt, :integer, :default => 0
      t.column :last_error, :text
      t.column :success_status, :string
      t.column :attempts, :integer
      t.column :failed, :boolean, :default => false
      t.column :created_at, :datetime
      t.column :updated_at, :datetime
      t.column :sent_at, :datetime
    end

    add_index :#{table_name.tableize}, :sent_at
    add_index :#{table_name.tableize}, :failed
  end

  def self.down
    drop_table :#{table_name.tableize}
  end
end
EOF

    puts <<-EOF
# =============================================================================================================================
# = Warning! If you're sending emails with attachments you probably want to use LONGTEXT instead of TEXT for the :mail column =
# =============================================================================================================================
Example extra migration:

class #{table_name.classify}MailTextToLongtext < ActiveRecord::Migration
  def self.up
    execute "ALTER TABLE #{table_name.tableize} CHANGE mail mail LONGTEXT"
  end

  def self.down
    execute "ALTER TABLE #{table_name.tableize} CHANGE mail mail TEXT"
  end
end
EOF
  end

  ##
  # Creates a new model using +table_name+ and prints it on stdout.

  def self.create_model(table_name)
    require 'active_support'
    puts <<-EOF
class #{table_name.classify} < ActiveRecord::Base
  validates_presence_of :from, :to, :mail

  def sent?
    not failed? and not sent_at.nil?
  end
end
EOF
  end

  ##
  # Prints a list of unsent emails and the last delivery attempt, if any.
  #
  # If ActiveRecord::Timestamp is not being used the arrival time will not be
  # known.  See http://api.rubyonrails.org/classes/ActiveRecord/Timestamp.html
  # to learn how to enable ActiveRecord::Timestamp.

  def self.mailq(table_name)
    klass = table_name.split('::').inject(Object) { |k,n| k.const_get n }
    emails = klass.find :all, :conditions => {:sent_at => nil, :failed => false}

    if emails.empty? then
      puts "Mail queue is empty"
      return
    end

    total_size = 0

    puts "-Queue ID- --Size-- ----Arrival Time---- -----Last attempt at------ -Attempts- -Sender/Recipient--------------------------------------"
    emails.each do |email|
      size = email.mail.length
      total_size += size

      create_timestamp = email.created_at rescue
                         Time.at(email.created_date) rescue # for Robot Co-op
                         nil

      created = if create_timestamp.nil? then
                  '             Unknown'
                else
                  create_timestamp.strftime '%a %b %d %H:%M:%S'
                end

      puts "%10d %8d %s   %s  %7d %s -> %s" % [email.id, size, created, Time.at(email.last_send_attempt) || ' '*19, email.attempts, email.from, email.to]
    end

    puts "-- #{total_size/1024} Kbytes in #{emails.length} Requests."
  end

  ##
  # Processes command line options in +args+

  def self.process_args(args)
    name = File.basename $0

    options = {}
    options[:Chdir] = '.'
    options[:Daemon] = false
    options[:Delay] = 60
    options[:MaxAge] = 86400 * 7
    options[:Once] = false
    options[:RailsEnv] = ENV['RAILS_ENV']
    options[:TableName] = 'Email'
    options[:Pidfile] = options[:Chdir] + '/log/ar_sendmail.pid'

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: #{name} [options]"
      opts.separator ''

      opts.separator "#{name} scans the email table for new messages and sends them to the"
      opts.separator "website's configured SMTP host."
      opts.separator ''
      opts.separator "#{name} must be run from a Rails application's root."

      opts.separator ''
      opts.separator 'Sendmail options:'

      opts.on("-b", "--batch-size BATCH_SIZE",
              "Maximum number of emails to send per delay",
              "Default: Deliver all available emails", Integer) do |batch_size|
        options[:BatchSize] = batch_size
      end

      opts.on(      "--delay DELAY",
              "Delay between checks for new mail",
              "in the database",
              "Default: #{options[:Delay]}", Integer) do |delay|
        options[:Delay] = delay
      end

      opts.on(      "--max-age MAX_AGE",
              "Maxmimum age for an email. After this",
              "it will be removed from the queue.",
              "Set to 0 to disable queue cleanup.",
              "Default: #{options[:MaxAge]} seconds", Integer) do |max_age|
        options[:MaxAge] = max_age
      end

      opts.on("-o", "--once",
              "Only check for new mail and deliver once",
              "Default: #{options[:Once]}") do |once|
        options[:Once] = once
      end

      opts.on("-d", "--daemonize",
              "Run as a daemon process",
              "Default: #{options[:Daemon]}") do |daemon|
        options[:Daemon] = true
      end

      opts.on("-p", "--pidfile PIDFILE",
              "Set the pidfile location",
              "Default: #{options[:Chdir]}#{options[:Pidfile]}", String) do |pidfile|
        options[:Pidfile] = pidfile
      end

      opts.on(      "--mailq",
              "Display a list of emails waiting to be sent") do |mailq|
        options[:MailQ] = true
      end

      opts.separator ''
      opts.separator 'Setup Options:'

      opts.on(      "--create-migration",
              "Prints a migration to add an Email table",
              "to stdout") do |create|
        options[:Migrate] = true
      end

      opts.on(      "--create-model",
              "Prints a model for an Email ActiveRecord",
              "object to stdout") do |create|
        options[:Model] = true
      end

      opts.separator ''
      opts.separator 'Generic Options:'

      opts.on("-c", "--chdir PATH",
              "Use PATH for the application path",
              "Default: #{options[:Chdir]}") do |path|
        usage opts, "#{path} is not a directory" unless File.directory? path
        usage opts, "#{path} is not readable" unless File.readable? path
        options[:Chdir] = path
      end

      opts.on("-e", "--environment RAILS_ENV",
              "Set the RAILS_ENV constant",
              "Default: #{options[:RailsEnv]}") do |env|
        options[:RailsEnv] = env
      end

      opts.on("-t", "--table-name TABLE_NAME",
              "Name of table holding emails",
              "Used for both sendmail and",
              "migration creation",
              "Default: #{options[:TableName]}") do |name|
        options[:TableName] = name
      end

      opts.on("-v", "--[no-]verbose",
              "Be verbose",
              "Default: #{options[:Verbose]}") do |verbose|
        options[:Verbose] = verbose
      end

      opts.on("-h", "--help",
              "You're looking at it") do
        usage opts
      end

      opts.on("--version", "Version of ARMailer") do
        usage "ar_mailer #{VERSION} (dvdplm fork)"
      end

      opts.separator ''
    end

    opts.parse! args

    return options if options.include? :Migrate or options.include? :Model
 
    ENV['RAILS_ENV'] = options[:RailsEnv]

    Dir.chdir options[:Chdir] do
      begin
        require 'config/environment'
      rescue LoadError
        usage opts, <<-EOF
#{name} must be run from a Rails application's root to deliver email.
#{Dir.pwd} does not appear to be a Rails application root.
          EOF
      end
    end

    return options
  end

  ##
  # Processes +args+ and runs as appropriate

  def self.run(args = ARGV)
    options = process_args args

    if options.include? :Migrate then
      create_migration options[:TableName]
      exit
    elsif options.include? :Model then
      create_model options[:TableName]
      exit
    elsif options.include? :MailQ then
      mailq options[:TableName]
      exit
    end

    if options[:Daemon] then
      require 'webrick/server'
      @@pid_file = File.expand_path(options[:Pidfile], options[:Chdir])
      if File.exists? @@pid_file
        # check to see if process is actually running
        pid = ''
        File.open(@@pid_file, 'r') {|f| pid = f.read.chomp }
        if system("ps -p #{pid} | grep #{pid}") # returns true if process is running, o.w. false
          $stderr.puts "Warning: The pid file #{@@pid_file} exists and ar_sendmail is running. Shutting down."
          exit
        else
          # not running, so remove existing pid file and continue
          self.remove_pid_file
          $stderr.puts "ar_sendmail is not running. Removing existing pid file and starting up..."
        end
      end
      WEBrick::Daemon.start
      File.open(@@pid_file, 'w') {|f| f.write("#{Process.pid}\n")}
    end

    new(options).run

  rescue SystemExit
    raise
  rescue SignalException
    exit
  rescue Exception => e
    $stderr.puts "Unhandled exception #{e.message}(#{e.class}):"
    $stderr.puts "\t#{e.backtrace.join "\n\t"}"
    exit 1
  end

  ##
  # Prints a usage message to $stderr using +opts+ and exits

  def self.usage(opts, message = nil)
    if message then
      $stderr.puts message
      $stderr.puts
    end

    $stderr.puts opts
    exit 1
  end

  ##
  # Creates a new ARSendmail.
  #
  # Valid options are:
  # <tt>:BatchSize</tt>:: Maximum number of emails to send per delay
  # <tt>:Delay</tt>:: Delay between deliver attempts
  # <tt>:TableName</tt>:: Table name that stores the emails
  # <tt>:Once</tt>:: Only attempt to deliver emails once when run is called
  # <tt>:Verbose</tt>:: Be verbose.

  def initialize(options = {})
    options[:Delay]     ||= 60
    options[:TableName] ||= 'Email'
    options[:MaxAge]    ||= 86400 * 7

    @batch_size   = options[:BatchSize]
    @delay        = options[:Delay]
    @email_class  = options[:TableName].constantize
    @once         = options[:Once]
    @verbose      = options[:Verbose]
    @max_age      = options[:MaxAge]

    @failed_auth_count = 0
  end

  ##
  # Removes unsent emails that have lived in the queue for too long. 
  # If max_age is set to 0, no emails will be removed; max_age defaults
  # to 7 days (86400 * 7)
  def cleanup
    return if @max_age == 0
    timeout = Time.now - @max_age
    conditions = ['last_send_attempt > 0 AND created_at < ? AND sent_at IS NULL', timeout]
    mail = @email_class.update_all({:failed => true}, conditions)

    log "#{self.class}#cleanup expired #{mail} emails from the queue"
  end

  ##
  # Delivers +emails+ to ActionMailer's SMTP server and destroys them.

  def deliver(emails)
    log "#{self.class}#deliver Delivering #{emails.size} emails through '#{smtp_settings[:address]}' as '#{(smtp_settings[:user] || smtp_settings[:user_name])}'"
    settings = [
      smtp_settings[:domain],
      (smtp_settings[:user] || smtp_settings[:user_name]),
      smtp_settings[:password],
      smtp_settings[:authentication]
    ]
    
    smtp = Net::SMTP.new(smtp_settings[:address], smtp_settings[:port])
    if smtp.respond_to?(:enable_starttls_auto) # NOTE: Ruby 1.8.7+ has TLS support built in (dvd, 11-05-2009)
      smtp.enable_starttls_auto unless smtp_settings[:tls] == false
    else
      settings << smtp_settings[:tls]
    end

    smtp.start(*settings) do |session|
      @failed_auth_count = 0
      until emails.empty? do
        email = emails.shift
        email.last_send_attempt = Time.now.to_i
        email.increment :attempts
        begin
          res = session.send_message email.mail, email.from, email.to
          email.failed = false
          email.sent_at = Time.now
          email.success_status = res.string rescue res.inspect # NOTE: some rubies return an Net::HTTP::Response here, others just a stupid String (dvd, 11-05-2009)
          
          log "#{self.class}#deliver sent email %011d from %s to %s: %p" %
                [email.id, email.from, email.to, res]
        rescue Net::SMTPFatalError => e
          log "#{self.class}#deliver 5xx error sending email %d, removing from queue: %p(%s):\n\t%s" % [email.id, e.message, e.class, e.backtrace.join("\n\t")]
          email.last_error = "Exception: #{e.class}\n\nMessage:\n#{e.message}\n\nBacktrace:\n#{e.backtrace.join("\n\t")}"
          email.failed = true
          session.reset
        rescue Net::SMTPServerBusy => e
          log "#{self.class}#deliver server too busy, sleeping #{@delay} seconds"
          email.last_error = "Exception: #{e.class}\n\nMessage:\n#{e.message}\n\nBacktrace:\n#{e.backtrace.join("\n\t")}"
          email.save! # TODO: the return here means we have to save the email before, so the attempts count stays correct (dvd, 11-05-2009)
          sleep delay
          return
        rescue Net::SMTPUnknownError, Net::SMTPSyntaxError, TimeoutError => e
          email.last_error = "Exception: #{e.class}\n\nMessage:\n#{e.message}\n\nBacktrace:\n#{e.backtrace.join("\n\t")}"
          log "#{self.class}#deliver error sending email %d: %p(%s):\n\t%s" %
                [email.id, e.message, e.class, e.backtrace.join("\n\t")]
          session.reset
        end
        email.save!
      end

    end
  rescue Net::SMTPAuthenticationError => e
    @failed_auth_count += 1
    if @failed_auth_count >= MAX_AUTH_FAILURES then
      log "#{self.class}#deliver authentication error, giving up: #{e.message}"
      raise e
    else
      log "#{self.class}#deliver authentication error, retrying: #{e.message}"
    end
    sleep delay
  rescue Net::SMTPServerBusy, SystemCallError, OpenSSL::SSL::SSLError
    # ignore SMTPServerBusy/EPIPE/ECONNRESET from Net::SMTP.start's ensure
  end

  ##
  # Prepares ar_sendmail for exiting

  def do_exit
    log "#{self.class}#deliver caught signal, shutting down"
    self.class.remove_pid_file
    exit
  end

  ##
  # Returns emails in email_class that haven't had a delivery attempt in the
  # last 300 seconds.
  # The records found are locked, so make sure you call this inside a
  # transaction or otherwise manually release to locks
  def find_emails
    options = { :conditions => ['sent_at IS NULL AND failed = ? AND (? - last_send_attempt) > 300', false, Time.now.to_i], :lock => true }
    options[:limit] = batch_size unless batch_size.nil?
    mail = @email_class.all(options)

    log "#{self.class}#deliver found #{mail.length} emails to send"
    mail
  end

  ##
  # Installs signal handlers to gracefully exit.

  def install_signal_handlers
    trap 'TERM' do do_exit end
    trap 'INT'  do do_exit end
  end

  ##
  # Logs +message+ if verbose

  def log(message)
    $stderr.puts message if @verbose
    ActionMailer::Base.logger.info "ar_sendmail ==> #{message}"
  end

  ##
  # Scans for emails and delivers them every delay seconds.  Only returns if
  # once is true.

  def run
    install_signal_handlers

    loop do
      now = Time.now
      begin
        cleanup
        Email.transaction do
          emails = find_emails
          deliver(emails) unless emails.empty?
        end
      rescue ActiveRecord::Transactions::TransactionError
      end
      break if @once
      sleep @delay if now + @delay > Time.now
    end
  end

  ##
  # Proxy to ActionMailer::Base::smtp_settings.  See
  # http://api.rubyonrails.org/classes/ActionMailer/Base.html
  # for instructions on how to configure ActionMailer's SMTP server.
  #
  # Falls back to ::server_settings if ::smtp_settings doesn't exist for
  # backwards compatibility.

  def smtp_settings
    ActionMailer::Base.smtp_settings rescue ActionMailer::Base.server_settings
  end

end
