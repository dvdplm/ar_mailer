require 'test/unit'
require 'rubygems'
require 'active_support'
require 'action_mailer'
require 'action_mailer/ar_mailer'
require 'test_helper'

##
# Pretend mailer

class Mailer < ActionMailer::Base
  self.delivery_method = :activerecord

  def mail
    @mail = Object.new
    def @mail.encoded() 'email' end
    def @mail.from() ['nobody@example.com'] end
    def @mail.destinations() %w[user1@example.com user2@example.com] end
  end

end

class TestARMailer < Test::Unit::TestCase

  def setup
    Mailer.email_class = Email

    Email.delete_all
    Mail.delete_all
  end

  def test_self_email_class_equals
    Mailer.email_class = Mail

    Mailer.deliver_mail

    assert_equal 2, Mail.count
  end

  def test_perform_delivery_activerecord
    Mailer.deliver_mail

    assert_equal 2, Email.count

    email = Email.first
    assert_equal 'email', email.mail
    assert_equal 'user1@example.com', email.to
    assert_equal 'nobody@example.com', email.from

    assert_equal 'user2@example.com', Email.last.to
  end

end

