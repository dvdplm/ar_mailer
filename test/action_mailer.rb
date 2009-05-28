require 'net/smtp'
require 'smtp_tls' unless Net::SMTP.instance_methods.include?("enable_starttls_auto")
require 'time'

class Net::SMTP

  @reset_called = 0

  @deliveries = []

  @send_message_block = nil

  @start_block = nil

  class << self

    attr_reader :deliveries
    attr_reader :send_message_block
    attr_accessor :reset_called

    send :remove_method, :start

  end

  def self.on_send_message(&block)
    @send_message_block = block
  end

  def self.on_start(&block)
    if block_given?
      @start_block = block
    else
      @start_block
    end
  end

  def self.clear_on_start
    @start_block = nil
  end

  def self.reset
    deliveries.clear
    on_start
    on_send_message
    @reset_called = 0
  end

  def start(*args)
    self.class.on_start.call if self.class.on_start
    yield self
  end

  alias test_old_reset reset if instance_methods.include? 'reset'

  def reset
    self.class.reset_called += 1
  end

  alias test_old_send_message send_message

  def send_message(mail, to, from)
    return self.class.send_message_block.call(mail, to, from) unless
      self.class.send_message_block.nil?
    self.class.deliveries << [mail, to, from]
    return "queued"
  end

end

##
# Stub for ActionMailer::Base

module ActionMailer; end

class ActionMailer::Base

  @server_settings = {}

  class << self
    attr_accessor :delivery_method
  end

  def self.logger
    o = Object.new
    def o.info(arg) end
    return o
  end

  def self.method_missing(meth, *args)
    meth.to_s =~ /deliver_(.*)/
    super unless $1
    new($1, *args).deliver!
  end

  def self.reset
    server_settings.clear
  end

  def self.server_settings
    @server_settings
  end

  def initialize(meth = nil)
    send meth if meth
  end

  def deliver!
    perform_delivery_activerecord @mail
  end

end

class String
  def classify
    self
  end

  def tableize
    self.downcase
  end

end

