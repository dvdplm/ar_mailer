ActiveRecord::Schema.define(:version => 0) do
  create_table :emails, :force => true do |t|
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

  add_index :emails, :sent_at
  add_index :emails, :failed
  
  create_table :mails, :force => true do |t|
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

  add_index :mails, :sent_at
  add_index :mails, :failed
  
end