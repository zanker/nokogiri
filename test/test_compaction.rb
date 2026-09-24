# frozen_string_literal: true

require "helper"

describe "compaction" do
  def skip_compaction_tests
    !GC.respond_to?(:verify_compaction_references)
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
end
