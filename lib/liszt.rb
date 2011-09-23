require "liszt/version"
require "liszt/instantizeable"
require "liszt/redis_list"

module Liszt
  mattr_accessor :redis

  # Set up a scoped ordering for this model.
  #
  # Liszt currently only supports one type of ranking per model. It also doesn't
  # currently support re-sorting lists when a scope changes. The assumption is
  # that attributes used as scopes won't change after creation.
  #
  # The other major limitation at the moment is that scopes can't be <tt>nil</tt>.
  # If a record has nil for a scope value, its associated list will never have
  # any items in it.
  #
  # @param [Hash] options
  # @option options [Symbol, Array] :scope The attribute or attributes to use
  #   as list constraints.
  # @option options [Hash] :conditions Any extra constraints to impose.
  # @option options [Proc] :sort_by A lambda to pass into initialize_list! the first
  #   time an item is added to an uninitialized list. It has the same semantics as
  #   <tt>Enumerable#sort_by</tt>.
  def acts_as_liszt(options = {})
    extend Instantizeable
    extend ClassMethods
    include InstanceMethods

    # Make "instantized" versions of the class methods.
    ClassMethods.instance_methods.each do |method|
      instantize method
    end

    options.reverse_merge! :conditions => {}, :scope => []

    @liszt_conditions = options[:conditions]
    @liszt_scope = Array(options[:scope]).sort_by(&:to_s)
    @liszt_query = nil
    @liszt_sort_by = options[:sort_by]
  end

  module ClassMethods
    def initialize_list!(obj={}, &block)
      objects = find(:all, :conditions => liszt_query(obj))

      # If the caller provided a block, sort the objects by that block's
      # output before populating the list with their ids. If not, put
      # the objects in descending order by id.
      ids = if block_given?
              objects.sort_by(&block).map(&:id)
            else
              if @lizst_sort_by
                objects.sort_by(&@lizst_sort_by).map(&:id)
              else
                objects.map(&:id).sort.reverse
              end
            end

      ordered_list(obj).clear_and_populate!(ids)
      ids
    end

    def ordered_list(obj={})
      Liszt::RedisList.new(liszt_key(obj))
    end

    def ordered_list_initialized?(obj={})
      ordered_list(obj).initialized?
    end

    def ordered_list_ids(obj={})
      return nil unless ordered_list_initialized?(obj)
      ordered_list(obj).all
    end

    def ordered_list_items(obj={}, double_check=false)
      return nil unless ordered_list_initialized?(obj)
      ids = ordered_list_ids(obj)

      if double_check
        objs = find(:all, :conditions => liszt_query(obj))
        real_ids = objs.map(&:id)
        unlisted_ids = real_ids - ids
        if unlisted_ids.count > 0
          ids = ordered_list(obj).clear_and_populate!(unlisted_ids + ids)
        end
      else
        objs = find_all_by_id(ids)
      end

      objs.sort_by { |obj| ids.index(obj.id) }
    end

    def clear_list(obj={})
      ordered_list(obj).clear
    end

    def meets_list_conditions?(obj={})
      @liszt_conditions.all? { |key, value| obj[key] == value }
    end

    private
    # Return the key for the Redis list that includes the given object.
    def liszt_key(obj={})
      key = "liszt:#{table_name}"
      @liszt_scope.each do |scope|
        key << ":#{scope}:#{obj[scope]}"
      end
      key
    end

    # Return the query that retrieves objects eligible to be
    # in the list that includes the given object.
    def liszt_query(obj={})
      if @liszt_query.nil?
        query = ['1 = 1']

        @liszt_conditions.each do |key, value|
          query.first << " AND (#{table_name}.#{key} "
          if value.nil?
            query.first << "IS NULL)"
          else
            query.first << "= ?)"
            query << value
          end
        end

        @liszt_scope.each do |scope|
          query.first << " AND (#{table_name}.#{scope} = ?)"
        end

        @liszt_query = query
      end

      @liszt_query + @liszt_scope.map { |scope| obj[scope] }
    end
  end

  module InstanceMethods
    def self.included(base)
      base.class_eval do
        after_create :add_to_list
        after_update :update_list
        after_destroy :remove_from_list
      end
    end

    def add_to_list
      if ordered_list_initialized?
        if meets_list_conditions?
          ordered_list.unshift(self.id)
        end
      else
        if @liszt_sort_by
          initialize_list!(&@liszt_sort_by)
        else
          initialize_list!
        end
      end
      true
    end

    def update_list
      if meets_list_conditions?
        add_to_list
      else
        remove_from_list
      end
      true
    end

    def remove_from_list
      ordered_list.remove(self.id)
      true
    end

    def move_to_top!
      ordered_list.move_to_top(self.id)
    end

    def move_up!
      ordered_list.move_up(self.id)
    end

    def move_down!
      ordered_list.move_down(self.id)
    end

    def move_to_bottom!
      ordered_list.move_to_bottom(self.id)
    end
  end
end

ActiveRecord::Base.extend Liszt
