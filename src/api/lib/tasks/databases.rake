require_relative '../../app/models/application_record'

module Rake
  module TaskManager
    def redefine_task(task_class, *args, &block)
      task_name, deps = resolve_args(args)
      task_name = task_class.scope_name(@scope, task_name)
      deps = [deps] unless deps.respond_to?(:to_ary)
      deps = deps.collect(&:to_s)
      task = @tasks[task_name.to_s] = task_class.new(task_name, self)
      task.application = self
      # task.add_comment(@last_comment)
      @last_comment = nil
      task.enhance(deps, &block)
      task
    end
  end
  class Task
    class << self
      def redefine_task(args, &block)
        Rake.application.redefine_task(self, args, &block)
      end
    end
  end
end

def redefine_task(args, &block)
  Rake::Task.redefine_task(args, &block)
end

namespace :db do
  namespace :structure do
    desc "Dump the database structure to a SQL file"
    task dump: :environment do
      structure = ''
      abcs = ActiveRecord::Base.configurations
      case abcs[Rails.env]["adapter"]
      when "mysql2"
        ActiveRecord::Base.establish_connection(abcs[Rails.env])
        con = ActiveRecord::Base.connection

        sql = "SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'"

        structure = con.select_all(sql, 'SCHEMA').map { |table|
          table.delete('Table_type')
          sql = "SHOW CREATE TABLE #{con.quote_table_name(table.to_a.first.last)}"
          con.exec_query(sql, 'SCHEMA').first['Create Table'] + ";\n\n"
        }.join
      else
        raise "Task not supported by '#{abcs[Rails.env]["adapter"]}'"
      end

      if ActiveRecord::Base.connection.supports_migrations?
        structure << ActiveRecord::Base.connection.dump_schema_information
      end

      structure.gsub!(%r{AUTO_INCREMENT=[0-9]* }, '')
      structure.gsub!('auto_increment', 'AUTO_INCREMENT')
      structure.gsub!(%r{default([, ])}, 'DEFAULT\1')
      structure.gsub!(%r{KEY  *}, 'KEY ')
      structure += "\n"
      # sort the constraint lines always in the same order
      new_structure = ''
      constraints = Array.new
      added_comma = false
      structure.each_line do |line|
        if line =~ /[ ]*CONSTRAINT/
          unless line.end_with?(",\n")
            added_comma = true
            line = line[0..-2] + ",\n"
          end
          constraints << line
        else
          if constraints.count > 0
            constraints.sort!
            new_structure += constraints.join
            if added_comma
              new_structure = new_structure[0..-3] + "\n"
            end
            constraints = Array.new
          end
          added_comma = false
          new_structure += line
        end
      end
      File.open("#{Rails.root}/db/structure.sql", "w+") { |f| f << new_structure }
    end

    desc "Verify that structure.sql in git is up to date"
    task verify: :environment do
      puts "Running rails db:migrate"
      Rake::Task["db:migrate"].invoke
      puts "Diffing the db/structure.sql"
      sh %{git diff --quiet db/structure.sql} do |ok, _|
        unless ok
          abort "Generated structure.sql differs from structure.sql stored in git. " +
            "Please run rake db:migrate and check the differences."
        end
      end
      puts "Everything looks fine!"
    end

    desc "Verify that structure.sql does not use any columns with type = bigint"
    task verify_no_bigint: :environment do
      puts 'Checking db/structure.sql for bigint'

      bigint_lines = %x{grep "bigint" #{Rails.root}/db/structure.sql}

      unless bigint_lines.blank?
        abort <<-STR
          Please do not use bigint column type in db/structure.sql.
          You may need to call create_table with `id: :integer` to avoid the id column using bigint.
        STR
      end

      puts 'Ok'
    end
  end

  desc 'Create the database, load the structure, and initialize with the seed data'
  redefine_task setup: :environment do
    Rake::Task["db:structure:load"].invoke
    Rake::Task["db:seed"].invoke
  end

  desc "Convert existing notifications to use JSON serialization for the event_payload column"
  task convert_notifications_serialization: :environment do
    NotificationForRakeTask.transaction do
      NotificationForRakeTask.all.find_each do |notification|
        json = yaml_to_json(notification.event_payload)
        notification.update_attributes!(event_payload: json)
      end
    end
  end
end

def yaml_to_json(yaml)
  YAML.safe_load(yaml)
      .traverse do |value|
        if value.is_a? String
          value.force_encoding('UTF-8')
        else
          value
        end
      end
      .to_json
end

# Notification model only for migration in order to avoid errors coming from the serialization in the actual Notification model
class NotificationForRakeTask < ::ApplicationRecord
  self.table_name = 'notifications'
  self.inheritance_column = :_type_disabled
end

# Hash extension is used to run force_encoding against each string value in the hash
# in rake tasks to convert yaml to json serialisation for event payloads
class Hash
  def traverse(&block)
    traverse_value(self, &block)
  end

  private

  def traverse_value(value, &block)
    if value.is_a? Hash
      value.each { |key, sub_value| value[key] = traverse_value(sub_value, &block) }

    elsif value.is_a? Array
      value.map { |element| traverse_value(element, &block) }

    else
      yield(value)

    end
  end
end
