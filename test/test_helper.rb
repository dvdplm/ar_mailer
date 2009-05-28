require 'active_record'
require 'active_record/migration'
config = YAML::load(IO.read(File.dirname(__FILE__) + '/db/database.yml'))
ActiveRecord::Base.logger = Logger.new(File.dirname(__FILE__) + "/test_debug.log")

ActiveRecord::Base.establish_connection(config['sqlite3mem'])

ActiveRecord::Migration.verbose = false
load(File.dirname(__FILE__) + "/db/schema.rb")

class Email < ActiveRecord::Base
  validates_presence_of :from, :to, :mail

  def sent?
    not failed? and not sent_at.nil?
  end
  
  # TODO: the tests used to have a fake Email class and no database. The reset method cleared out the in-memory hash. Remove this dependency ASAP. (dvd, 28-05-2009)
  def self.reset
    delete_all
  end
  
  # TODO: the tests used to have a fake Email class and no database. The reset method cleared out the in-memory hash. Remove this dependency ASAP. (dvd, 28-05-2009)
  def self.records
    all
  end
end

# We have to different classes, so we can do assertions on ar_mailer configurability
class Mail < ActiveRecord::Base
  validates_presence_of :from, :to, :mail

  def sent?
    not failed? and not sent_at.nil?
  end
  
  # TODO: the tests used to have a fake Email class and no database. The reset method cleared out the in-memory hash. Remove this dependency ASAP. (dvd, 28-05-2009)
  def self.reset
    delete_all
  end
  
  # TODO: the tests used to have a fake Email class and no database. The reset method cleared out the in-memory hash. Remove this dependency ASAP. (dvd, 28-05-2009)
  def self.records
    all
  end
end