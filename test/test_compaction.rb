# frozen_string_literal: true

require "helper"
require "weakref"

describe "compaction" do
  def skip_compaction_tests
    !GC.respond_to?(:verify_compaction_references)
  end

  [:nodes, :namespaces].product([false, true], [false, true]).each do |result_type, return_array, clear_result|
    describe "callback #{result_type} as #{return_array ? "arrays" : "node sets"} (cleared: #{clear_result})" do
      # A callback turns GC stress on, so make sure a failed evaluation doesn't leave it on.
      after { GC.stress = false }

      let(:function_class) do
        compact = method(:gc_verify_compaction_references)
        selector = (result_type == :namespaces) ? "/other/namespace::*" : "/other/child"
        Class.new do
          define_method(:fresh) do
            document = Nokogiri::XML('<other xmlns:kept="urn:kept"><child>retained</child></other>')
            @document = WeakRef.new(document)
            nodes = document.xpath(selector)
            if clear_result && !return_array
              nodes = Nokogiri::XML::NodeSet.new(Nokogiri::XML("<owner/>"), nodes.to_a)
            end
            result = return_array ? nodes.to_a : nodes
            @result = result if clear_result
            # Collect on every allocation while libxml2 takes over the result, until the next callback.
            GC.stress = true
            result
          end

          def empty
            GC.stress = false
            Nokogiri::XML("<empty/>").xpath("missing")
          end

          def clear
            until @result.empty?
              @result.pop
            end
            empty
          end

          define_method(:verify) do
            compact.call
            raise "callback result document was collected" if !@document.weakref_alive?

            true
          end
        end
      end

      it "keeps returned XPath nodes alive until evaluation finishes" do
        skip("GC compaction is unavailable") if skip_compaction_tests

        handler = function_class.new
        document = Nokogiri::XML("<root/>")
        next_function = clear_result ? "clear" : "empty"
        expression = "(nokogiri:fresh() | nokogiri:#{next_function}() | nokogiri:empty())[nokogiri:verify()]"
        expression += "/parent::node()" if result_type == :namespaces

        result = document.xpath(expression, handler)
        assert_equal([(result_type == :namespaces) ? "other" : "child"], result.map(&:name))
        assert_equal("retained", result.text)
      end

      it "keeps returned XSLT nodes alive until the transform finishes" do
        skip("GC compaction is unavailable") if skip_compaction_tests

        next_function = clear_result ? "clear" : "empty"
        expression = "(ext:fresh() | ext:#{next_function}() | ext:empty())[ext:verify()]"
        expression += "/parent::node()" if result_type == :namespaces
        stylesheet = Nokogiri::XSLT(<<~XML, "urn:retained-results" => function_class)
          <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:ext="urn:retained-results" extension-element-prefixes="ext">
            <xsl:template match="/">
              <out><xsl:copy-of select="#{expression}"/></out>
            </xsl:template>
          </xsl:stylesheet>
        XML
        document = Nokogiri::XML("<root/>")

        result = stylesheet.transform(document)
        assert_equal([(result_type == :namespaces) ? "other" : "child"], result.root.element_children.map(&:name))
        assert_equal("retained", result.root.content)
      end
    end
  end

  describe Nokogiri::XML::Node do
    it "compacts safely" do # https://github.com/sparklemotion/nokogiri/pull/2579
      skip if skip_compaction_tests

      refute_valgrind_errors do
        big_doc = "<root>" + ("a".."zz").map { |x| "<#{x}>#{x}</#{x}>" }.join + "</root>"
        doc = Nokogiri.XML(big_doc)

        # ensure a bunch of node objects have been wrapped
        doc.root.children.each(&:inspect)

        # compact the heap and try to get the node wrappers to move
        gc_verify_compaction_references

        # access the node wrappers and make sure they didn't move
        doc.root.children.each(&:inspect)
      end
    end
  end

  describe Nokogiri::XML::Namespace do
    it "namespace_scopes" do
      skip if skip_compaction_tests

      doc = Nokogiri::XML(<<~EOF)
        <root xmlns="http://example.com/root" xmlns:bar="http://example.com/bar">
          <first/>
          <second xmlns="http://example.com/child"/>
          <third xmlns:foo="http://example.com/foo"/>
        </root>
      EOF

      refute_valgrind_errors do
        doc.at_xpath("//root:first", "root" => "http://example.com/root").namespace_scopes.inspect

        gc_verify_compaction_references

        doc.at_xpath("//root:first", "root" => "http://example.com/root").namespace_scopes.inspect
      end
    end

    it "remove_namespaces!" do
      skip if skip_compaction_tests

      doc = Nokogiri::XML(<<~XML)
        <root xmlns:a="http://a.flavorjon.es/" xmlns:b="http://b.flavorjon.es/">
          <a:foo>hello from a</a:foo>
          <b:foo>hello from b</b:foo>
          <container xmlns:c="http://c.flavorjon.es/">
            <c:foo c:attr='attr-value'>hello from c</c:foo>
          </container>
        </root>
      XML

      refute_valgrind_errors do
        namespaces = doc.root.namespaces
        namespaces.each(&:inspect)
        doc.remove_namespaces!

        gc_verify_compaction_references

        namespaces.each(&:inspect)
      end
    end
  end

  describe Nokogiri::XSLT::Stylesheet do
    let(:document) { Nokogiri::XML("<root><employee>Jane</employee></root>") }

    [false, true].each do |nested|
      it "keeps extension instances alive during #{nested ? "nested" : "ordinary"} transforms" do
        skip("GC compaction is unavailable") if skip_compaction_tests

        compact = method(:gc_verify_compaction_references)
        stylesheet = nil
        compacting_extension = Class.new do
          define_method(:run) do
            stylesheet.transform(Nokogiri::XML("<nested/>")) if nested
            compact.call
            "compacted"
          end
        end
        other_extension = Class.new do
          def run
            "alive"
          end
        end

        stylesheet = Nokogiri::XSLT(<<~XSL, "urn:compacting" => compacting_extension, "urn:other" => other_extension)
          <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:a="urn:compacting" xmlns:b="urn:other" extension-element-prefixes="a b">
            <xsl:template match="root">
              <out><xsl:value-of select="a:run()"/><xsl:value-of select="b:run()"/></out>
            </xsl:template>
            <xsl:template match="nested"><out>inner</out></xsl:template>
          </xsl:stylesheet>
        XSL

        assert_equal("compactedalive", stylesheet.transform(document).root.text)
      end
    end

    it "keeps transform params intact when coercing one of them compacts" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      compact = method(:gc_verify_compaction_references)
      # A later coercion can move strings converted on earlier iterations.
      trigger = Class.new do
        define_method(:to_str) do
          compact.call
          "'triggered'"
        end
      end.new

      stylesheet = Nokogiri::XSLT(<<~XSL)
        <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
          <xsl:param name="title"/>
          <xsl:param name="trigger"/>
          <xsl:template match="/"><out><xsl:value-of select="$title"/></out></xsl:template>
        </xsl:stylesheet>
      XSL

      result = stylesheet.transform(document, ["title", "'Employee List'", "trigger", trigger])

      assert_equal("Employee List", result.at_xpath("//out").text)
    end
  end
end
