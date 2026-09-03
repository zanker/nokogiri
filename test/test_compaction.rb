# frozen_string_literal: true

require "helper"

describe "compaction" do
  def skip_compaction_tests
    !GC.respond_to?(:verify_compaction_references)
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

  describe Nokogiri::XML::SAX::PushParser do
    it "keeps parsing after compaction" do # https://github.com/sparklemotion/nokogiri/issues/3665
      skip if skip_compaction_tests

      # the SAX parser whose address libxml2 holds is reachable only through PushParser's
      # @sax_parser ivar, so nothing keeps it in place
      parser = Nokogiri::XML::SAX::PushParser.new(Nokogiri::SAX::TestCase::Doc.new)

      gc_verify_compaction_references

      parser << "<root><alpha/></root>"
      parser.finish

      assert_equal([["root", []], ["alpha", []]], parser.document.start_elements)
    end
  end

  describe Nokogiri::HTML4::SAX::PushParser do
    it "keeps parsing after compaction" do # https://github.com/sparklemotion/nokogiri/issues/3665
      skip if skip_compaction_tests

      parser = Nokogiri::HTML4::SAX::PushParser.new(Nokogiri::SAX::TestCase::Doc.new)

      gc_verify_compaction_references

      parser << "<html><body><p>hello</p></body></html>"
      parser.finish

      assert_equal(["html", "body", "p"], parser.document.start_elements.map(&:first))
    end
  end

  describe Nokogiri::XML::Reader do
    it "reads an IO after compaction" do # https://github.com/sparklemotion/nokogiri/issues/3668
      skip if skip_compaction_tests

      # the reader is built in a frame that pops, so the IO is reachable only through Reader#source.
      # An IO held in a live local is pinned by the machine stack scan and would not move.
      reader = -> { Nokogiri::XML::Reader.from_io(StringIO.new("<root>#{"<a/>" * 100}</root>")) }.call

      gc_verify_compaction_references

      names = []
      reader.each { |node| names << node.name if node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT }

      assert_equal(["root"] + (["a"] * 100), names)
    end

    it "reads a String after compaction" do # https://github.com/sparklemotion/nokogiri/issues/3666
      skip if skip_compaction_tests

      # a String this short carries its bytes in the object slot, so they move with it. Only libxml2
      # < 2.11 reads the caller's buffer lazily; newer versions copy it up front.
      reader = -> { Nokogiri::XML::Reader.from_memory(+"<root><a>hello</a></root>") }.call

      gc_verify_compaction_references

      values = []
      reader.each { |node| values << node.value if node.value? }

      assert_equal(["hello"], values)
    end
  end

  describe Nokogiri::XML::SAX::ParserContext do
    it "parses an IO after compaction" do # https://github.com/sparklemotion/nokogiri/issues/3669
      skip if skip_compaction_tests

      context = -> { Nokogiri::XML::SAX::ParserContext.io(StringIO.new("<root><alpha/></root>")) }.call

      gc_verify_compaction_references

      handler = Nokogiri::SAX::TestCase::Doc.new
      context.parse_with(Nokogiri::XML::SAX::Parser.new(handler))

      assert_equal([["root", []], ["alpha", []]], handler.start_elements)
    end
  end

  describe Nokogiri::XSLT::Stylesheet do
    let(:document) { Nokogiri::XML("<root><employee>Jane</employee></root>") }

    it "transforms after compaction" do # https://github.com/sparklemotion/nokogiri/pull/3667
      skip if skip_compaction_tests

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

      # libxslt reads the stylesheet's own VALUE back out of `_private` to set up the extension
      # module, so the stylesheet is parked off the stack where the GC will move it
      held = [-> { Nokogiri::XSLT(stylesheet_source) }.call]

      gc_verify_compaction_references

      assert_equal("JANE", held.first.transform(document).at_xpath("//out").text)
    end

    it "keeps transform params intact when coercing one of them compacts" do # https://github.com/sparklemotion/nokogiri/issues/3670
      skip if skip_compaction_tests

      compact = method(:gc_verify_compaction_references)
      # StringValueCStr calls #to_str, which is arbitrary Ruby: it can relocate or collect the
      # strings the params loop converted on earlier iterations
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
