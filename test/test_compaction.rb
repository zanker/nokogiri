# frozen_string_literal: true

require "helper"
require "weakref"

describe "compaction" do
  def skip_compaction_tests
    !GC.respond_to?(:verify_compaction_references)
  end

  def with_auto_compaction
    previous_auto_compact = GC.auto_compact
    GC.auto_compact = true
    yield
  ensure
    GC.auto_compact = previous_auto_compact
  end

  [:nodes, :namespaces].product([false, true], [false, true]).each do |result_type, return_array, clear_result|
    describe "callback #{result_type} as #{return_array ? "arrays" : "node sets"} (cleared: #{clear_result})" do
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
            result
          end

          def empty
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
            raise "GC stress was not restored" if !GC.stress
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

        with_auto_compaction do
          result = stress_memory_while { document.xpath(expression, handler) }
          assert_equal([(result_type == :namespaces) ? "other" : "child"], result.map(&:name))
          assert_equal("retained", result.text)
        end
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

        with_auto_compaction do
          result = stress_memory_while { stylesheet.transform(document) }
          assert_equal([(result_type == :namespaces) ? "other" : "child"], result.root.element_children.map(&:name))
          assert_equal("retained", result.root.content)
        end
      end
    end
  end

  describe Nokogiri::XML::XPathContext do
    it "pins arguments in heap-allocated callback buffers" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      compact = method(:gc_verify_compaction_references)
      handler = Object.new
      handler.define_singleton_method(:join) do |*values|
        compact.call
        values.join
      end
      arguments = Array.new(200) { |i| "value#{i}" }
      expression = "nokogiri:join(#{arguments.map { |value| "'#{value}'" }.join(",")})"

      assert_equal(arguments.join, Nokogiri::XML("<root/>").xpath(expression, handler))
    end
  end

  [Nokogiri::XML::SAX, Nokogiri::HTML4::SAX].each do |sax|
    describe sax::ParserContext do
      it "pins the parser while callbacks compact the heap" do
        skip("GC compaction is unavailable") if skip_compaction_tests

        compact = method(:gc_verify_compaction_references)
        names = []
        handler = Class.new(Nokogiri::XML::SAX::Document) do
          define_method(:start_element) do |name, _attributes = []|
            names << name
            compact.call
          end
        end.new
        context = sax::ParserContext.memory("<html><body><p>one</p><p>two</p></body></html>")
        context.parse_with(sax::Parser.new(handler))

        assert_equal(["html", "body", "p", "p"], names)
      end
    end
  end

  if Nokogiri.uses_gumbo?
    describe Nokogiri::HTML5::DocumentFragment do
      it "releases context buffers when a callback raises or throws" do
        document = Nokogiri::HTML5('<math><annotation-xml encoding="text/html"/></math>')
        context = document.at_css("annotation-xml")
        error = RuntimeError.new("expected")
        action = -> { raise error }
        document.define_singleton_method(:internal_subset) { action.call }

        assert_same(error, assert_raises(RuntimeError) do
          Nokogiri::HTML5::DocumentFragment.new(document, "<a>ok</a>", context)
        end)
        action = -> { throw(:stop, :done) }
        assert_equal(:done, catch(:stop) do
          Nokogiri::HTML5::DocumentFragment.new(document, "<a>ok</a>", context)
        end)
        action = -> {}

        fragment = Nokogiri::HTML5::DocumentFragment.new(document, "<a>ok</a>", context)
        assert_equal("<a>ok</a>", fragment.to_html)
      end

      it "snapshots context names and encodings before later callbacks" do
        document = Nokogiri::HTML5('<math><annotation-xml encoding="text/html"/></math>')
        context = document.at_css("annotation-xml")
        tag_name = +"annotation-xml"
        encoding = +"text/html"
        context.define_singleton_method(:name) { tag_name }
        context.define_singleton_method(:[]) { |_key| encoding }
        document.define_singleton_method(:internal_subset) do
          tag_name.clear
          encoding.clear
          nil
        end

        fragment = Nokogiri::HTML5::DocumentFragment.new(document, "<a>ok</a>", context)
        assert_equal("<a>ok</a>", fragment.to_html)
        assert_nil(fragment.children.first.namespace)
      end

      it "retains temporary context names and encodings across compaction" do
        skip("GC compaction is unavailable") if skip_compaction_tests

        compact = method(:gc_verify_compaction_references)
        document = Nokogiri::HTML5('<math><annotation-xml encoding="text/html"/></math>')
        context = document.at_css("annotation-xml")
        context.define_singleton_method(:name) { +"annotation-xml" }
        context.define_singleton_method(:[]) { |_key| +"text/html" }
        document.define_singleton_method(:internal_subset) do
          compact.call
          nil
        end

        fragment = Nokogiri::HTML5::DocumentFragment.new(document, "<a>ok</a>", context)
        assert_equal("<a>ok</a>", fragment.to_html)
        assert_nil(fragment.children.first.namespace)
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

  describe Nokogiri::XML::Document do
    it "retains inclusive namespaces while canonicalization callbacks compact" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      namespace = Object.new
      namespace.define_singleton_method(:to_str) { +"kept" }
      doc = Nokogiri::XML('<doc xmlns:kept="urn:kept"><child/></doc>')
      output = doc.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0, [namespace]) do
        gc_verify_compaction_references
        true
      end

      assert_equal('<doc xmlns:kept="urn:kept"><child></child></doc>', output)
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

  describe Nokogiri::XML::SAX::PushParser do
    it "keeps parsing after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      # Keep the SAX parser off the machine stack so only PushParser's @sax_parser references it.
      parser = Nokogiri::XML::SAX::PushParser.new(Nokogiri::SAX::TestCase::Doc.new)

      gc_verify_compaction_references

      parser << "<root><alpha/></root>"
      parser.finish

      assert_equal([["root", []], ["alpha", []]], parser.document.start_elements)
    end
  end

  describe Nokogiri::HTML4::SAX::PushParser do
    it "keeps parsing after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      parser = Nokogiri::HTML4::SAX::PushParser.new(Nokogiri::SAX::TestCase::Doc.new)

      gc_verify_compaction_references

      parser << "<html><body><p>hello</p></body></html>"
      parser.finish

      assert_equal(["html", "body", "p"], parser.document.start_elements.map(&:first))
    end
  end

  describe Nokogiri::XML::Reader do
    it "reads an IO after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      # Construct the IO in a separate frame so a live stack reference cannot pin it.
      reader = -> { Nokogiri::XML::Reader.from_io(StringIO.new("<root>#{"<a/>" * 100}</root>")) }.call

      gc_verify_compaction_references

      names = []
      reader.each { |node| names << node.name if node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT }

      assert_equal(["root"] + (["a"] * 100), names)
    end

    it "reads a String after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      # libxml2 < 2.11 reads this embedded string lazily, so its buffer must stay pinned.
      reader = -> { Nokogiri::XML::Reader.from_memory(+"<root><a>hello</a></root>") }.call

      gc_verify_compaction_references

      values = []
      reader.each { |node| values << node.value if node.value? }

      assert_equal(["hello"], values)
    end
  end

  describe Nokogiri::XML::SAX::ParserContext do
    it "parses an IO after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      context = -> { Nokogiri::XML::SAX::ParserContext.io(StringIO.new("<root><alpha/></root>")) }.call

      gc_verify_compaction_references

      handler = Nokogiri::SAX::TestCase::Doc.new
      context.parse_with(Nokogiri::XML::SAX::Parser.new(handler))

      assert_equal([["root", []], ["alpha", []]], handler.start_elements)
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

    it "transforms after compaction" do
      skip("GC compaction is unavailable") if skip_compaction_tests

      Nokogiri::XSLT.register("http://nokogiri.org/test/compaction", Class.new do
        def shout(nodes)
          nodes.first.content.upcase
        end
      end)

      stylesheet_source = <<~XSL
        <xsl:stylesheet version="1.0"
                        xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                        xmlns:ex="http://nokogiri.org/test/compaction"
                        extension-element-prefixes="ex">
          <xsl:template match="/"><out><xsl:value-of select="ex:shout(//employee)"/></out></xsl:template>
        </xsl:stylesheet>
      XSL

      # Hold the stylesheet off the machine stack so its wrapper can move.
      held = [-> { Nokogiri::XSLT(stylesheet_source) }.call]

      gc_verify_compaction_references

      assert_equal("JANE", held.first.transform(document).at_xpath("//out").text)
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
