# frozen_string_literal: true

module RuboCop
  module Cop
    # This module checks for Ruby 3.1's hash value omission syntax.
    # rubocop:disable Metrics/ModuleLength
    module HashShorthandSyntax
      OMIT_HASH_VALUE_MSG = 'Omit the hash value.'
      EXPLICIT_HASH_VALUE_MSG = 'Include the hash value.'
      DO_NOT_MIX_MSG_PREFIX = 'Do not mix explicit and implicit hash values.'
      DO_NOT_MIX_OMIT_VALUE_MSG = "#{DO_NOT_MIX_MSG_PREFIX} #{OMIT_HASH_VALUE_MSG}"
      DO_NOT_MIX_EXPLICIT_VALUE_MSG = "#{DO_NOT_MIX_MSG_PREFIX} #{EXPLICIT_HASH_VALUE_MSG}"

      def on_hash_for_mixed_shorthand(hash_node)
        return if ignore_mixed_hash_shorthand_syntax?(hash_node)

        hash_value_type_breakdown = breakdown_value_types_of_hash(hash_node)

        if hash_with_mixed_shorthand_syntax?(hash_value_type_breakdown)
          mixed_shorthand_syntax_check(hash_value_type_breakdown)
        else
          no_mixed_shorthand_syntax_check(hash_value_type_breakdown)
        end
      end

      def on_pair(node)
        return if ignore_hash_shorthand_syntax?(node)

        hash_key_source = node.key.source

        if enforced_shorthand_syntax == 'always'
          return if node.value_omission? || require_hash_value?(hash_key_source, node)

          message = OMIT_HASH_VALUE_MSG
          replacement = "#{hash_key_source}:"
          self.config_to_allow_offenses = { 'Enabled' => false }
        else
          return unless node.value_omission?

          message = EXPLICIT_HASH_VALUE_MSG
          replacement = "#{hash_key_source}: #{hash_key_source}"
        end

        register_offense(node, message, replacement)
      end

      private

      # rubocop:disable Metrics/AbcSize
      def register_offense(node, message, replacement)
        add_offense(node.value, message: message) do |corrector|
          if (def_node = def_node_that_require_parentheses(node))
            white_spaces = range_between(def_node.loc.selector.end_pos,
                                         def_node.first_argument.source_range.begin_pos)
            corrector.replace(white_spaces, '(')

            last_argument = def_node.arguments.last
            corrector.insert_after(last_argument, ')') if node == last_argument.pairs.last
          end
          corrector.replace(node, replacement)
        end
      end
      # rubocop:enable Metrics/AbcSize

      def ignore_mixed_hash_shorthand_syntax?(hash_node)
        target_ruby_version <= 3.0 || enforced_shorthand_syntax != 'consistent' ||
          !hash_node.hash_type?
      end

      def ignore_hash_shorthand_syntax?(pair_node)
        target_ruby_version <= 3.0 || enforced_shorthand_syntax == 'either' ||
          enforced_shorthand_syntax == 'consistent' ||
          !pair_node.parent.hash_type?
      end

      def enforced_shorthand_syntax
        cop_config.fetch('EnforcedShorthandSyntax', 'always')
      end

      def require_hash_value?(hash_key_source, node)
        return true if !node.key.sym_type? || require_hash_value_for_around_hash_literal?(node)

        hash_value = node.value
        return true unless hash_value.send_type? || hash_value.lvar_type?

        hash_key_source != hash_value.source || hash_key_source.end_with?('!', '?')
      end

      def require_hash_value_for_around_hash_literal?(node)
        return false unless (method_dispatch_node = find_ancestor_method_dispatch_node(node))

        !node.parent.braces? &&
          !use_element_of_hash_literal_as_receiver?(method_dispatch_node, node.parent) &&
          use_modifier_form_without_parenthesized_method_call?(method_dispatch_node)
      end

      def def_node_that_require_parentheses(node)
        last_pair = node.parent.pairs.last
        return unless last_pair.key.source == last_pair.value.source
        return unless (method_dispatch_node = find_ancestor_method_dispatch_node(node))
        return unless without_parentheses_call_expr_follows?(method_dispatch_node)

        def_node = node.each_ancestor(:send, :csend, :super).first

        def_node unless def_node && def_node.arguments.empty?
      end

      def find_ancestor_method_dispatch_node(node)
        ancestor = node.parent.parent

        ancestor if (ancestor&.call_type? || ancestor&.super_type?) && !brackets?(ancestor)
      end

      def brackets?(method_dispatch_node)
        method_dispatch_node.method?(:[]) || method_dispatch_node.method?(:[]=)
      end

      def use_element_of_hash_literal_as_receiver?(ancestor, parent)
        # `{value:}.do_something` is a valid syntax.
        ancestor.send_type? && ancestor.receiver == parent
      end

      def use_modifier_form_without_parenthesized_method_call?(ancestor)
        return false if ancestor.respond_to?(:parenthesized?) && ancestor.parenthesized?

        ancestor.ancestors.any? { |node| node.respond_to?(:modifier_form?) && node.modifier_form? }
      end

      def without_parentheses_call_expr_follows?(ancestor)
        return false unless ancestor.respond_to?(:parenthesized?) && !ancestor.parenthesized?

        right_sibling = ancestor.right_sibling
        right_sibling ||= ancestor.each_ancestor.find do |node|
          node.assignment? || node.send_type?
        end&.right_sibling

        !!right_sibling
      end

      def breakdown_value_types_of_hash(hash_node)
        hash_node.pairs.group_by do |pair_node|
          if pair_node.value_omission?
            :value_omitted
          elsif require_hash_value?(pair_node.key.source, pair_node)
            :value_needed
          else
            :value_omittable
          end
        end
      end

      def hash_with_mixed_shorthand_syntax?(hash_value_type_breakdown)
        hash_value_type_breakdown.keys.size > 1
      end

      def hash_with_values_that_cant_be_omitted?(hash_value_type_breakdown)
        hash_value_type_breakdown[:value_needed]&.any?
      end

      def each_omitted_value_pair(hash_value_type_breakdown, &block)
        hash_value_type_breakdown[:value_omitted]&.each(&block)
      end

      def each_omittable_value_pair(hash_value_type_breakdown, &block)
        hash_value_type_breakdown[:value_omittable]&.each(&block)
      end

      def mixed_shorthand_syntax_check(hash_value_type_breakdown)
        if hash_with_values_that_cant_be_omitted?(hash_value_type_breakdown)
          each_omitted_value_pair(hash_value_type_breakdown) do |pair_node|
            hash_key_source = pair_node.key.source
            replacement = "#{hash_key_source}: #{hash_key_source}"
            register_offense(pair_node, DO_NOT_MIX_EXPLICIT_VALUE_MSG, replacement)
          end
        else
          each_omittable_value_pair(hash_value_type_breakdown) do |pair_node|
            hash_key_source = pair_node.key.source
            replacement = "#{hash_key_source}:"
            register_offense(pair_node, DO_NOT_MIX_OMIT_VALUE_MSG, replacement)
          end
        end
      end

      def no_mixed_shorthand_syntax_check(hash_value_type_breakdown)
        return if hash_with_values_that_cant_be_omitted?(hash_value_type_breakdown)

        each_omittable_value_pair(hash_value_type_breakdown) do |pair_node|
          hash_key_source = pair_node.key.source
          replacement = "#{hash_key_source}:"
          register_offense(pair_node, OMIT_HASH_VALUE_MSG, replacement)
        end
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
