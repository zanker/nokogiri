#include <nokogiri.h>

VALUE cNokogiriXsltStylesheet;

static void
mark(void *data)
{
  nokogiriXsltStylesheetTuple *wrapper = (nokogiriXsltStylesheetTuple *)data;
  rb_gc_mark(wrapper->func_instances);
  if (RTEST(wrapper->func_instances)) {
    /* libxslt retains each module's data array until the transform shuts down. */
    for (long i = 0; i < RARRAY_LEN(wrapper->func_instances); i++) {
      rb_gc_mark(rb_ary_entry(wrapper->func_instances, i));
    }
  }
}

static void
dealloc(void *data)
{
  nokogiriXsltStylesheetTuple *wrapper = (nokogiriXsltStylesheetTuple *)data;
  xsltStylesheetPtr doc = wrapper->ss;
  xsltFreeStylesheet(doc);
  ruby_xfree(wrapper);
}

static const rb_data_type_t nokogiri_xslt_stylesheet_tuple_type = {
  .wrap_struct_name = "nokogiriXsltStylesheetTuple",
  .function = {
    .dmark = mark,
    .dfree = dealloc,
  },
  .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

PRINTFLIKE_DECL(2, 3)
static void
xslt_generic_error_handler(void *ctx, const char *msg, ...)
{
  VALUE message;

#ifdef TRUFFLERUBY_NOKOGIRI_SYSTEM_LIBRARIES
  /* It is not currently possible to pass var args from native
     functions to sulong, so we work around the issue here. */
  message = rb_sprintf("xslt_generic_error_handler: %s", msg);
#else
  va_list args;
  va_start(args, msg);
  message = rb_vsprintf(msg, args);
  va_end(args);
#endif

  rb_str_concat((VALUE)ctx, message);
}

VALUE
Nokogiri_wrap_xslt_stylesheet(xsltStylesheetPtr ss)
{
  VALUE self;
  nokogiriXsltStylesheetTuple *wrapper;

  self = TypedData_Make_Struct(
           cNokogiriXsltStylesheet,
           nokogiriXsltStylesheetTuple,
           &nokogiri_xslt_stylesheet_tuple_type,
           wrapper
         );

  ss->_private = (void *)self;
  wrapper->ss = ss;
  wrapper->func_instances = rb_ary_new();

  return self;
}

/*
 * call-seq:
 *   parse_stylesheet_doc(document)
 *
 * Parse an XSLT::Stylesheet from +document+.
 *
 * [Parameters]
 * - +document+ (Nokogiri::XML::Document) the document to be parsed.
 *
 * [Returns] Nokogiri::XSLT::Stylesheet
 */
static VALUE
parse_stylesheet_doc(VALUE klass, VALUE xmldocobj)
{
  xmlDocPtr xml, xml_cpy;
  VALUE errstr, exception;
  xsltStylesheetPtr ss ;

  xml = noko_xml_document_unwrap(xmldocobj);

  errstr = rb_str_new(0, 0);
  xsltSetGenericErrorFunc((void *)errstr, xslt_generic_error_handler);

  xml_cpy = xmlCopyDoc(xml, 1); /* 1 => recursive */
  ss = xsltParseStylesheetDoc(xml_cpy);

  xsltSetGenericErrorFunc(NULL, NULL);

  if (!ss) {
    xmlFreeDoc(xml_cpy);
    exception = rb_exc_new3(rb_eRuntimeError, errstr);
    rb_exc_raise(exception);
  }

  return Nokogiri_wrap_xslt_stylesheet(ss);
}


/*
 * call-seq:
 *   serialize(document)
 *
 * Serialize +document+ to an xml string, as specified by the +method+ parameter in the Stylesheet.
 */
static VALUE
rb_xslt_stylesheet_serialize(VALUE self, VALUE xmlobj)
{
  xmlDocPtr xml ;
  nokogiriXsltStylesheetTuple *wrapper;
  xmlChar *doc_ptr ;
  int doc_len ;
  VALUE rval ;

  xml = noko_xml_document_unwrap(xmlobj);
  TypedData_Get_Struct(
    self,
    nokogiriXsltStylesheetTuple,
    &nokogiri_xslt_stylesheet_tuple_type,
    wrapper
  );
  xsltSaveResultToString(&doc_ptr, &doc_len, xml, wrapper->ss);
  rval = NOKOGIRI_STR_NEW(doc_ptr, doc_len);
  xmlFree(doc_ptr);
  return rval ;
}


/*
 * Build the C-string params array passed to xsltApplyStylesheet.
 *
 * Each param is copied, because StringValueCStr can run arbitrary Ruby (#to_str on a non-String, or
 * a reallocation to null-terminate), which can move or collect the strings converted on earlier
 * iterations.
 */
typedef struct {
  VALUE rb_param;
  long param_len;
  const char **params;
} build_xslt_params_args_t;

static VALUE
build_xslt_params(VALUE args_ptr)
{
  build_xslt_params_args_t *args = (build_xslt_params_args_t *)args_ptr;

  for (long j = 0; j < args->param_len; j++) {
    VALUE entry = rb_ary_entry(args->rb_param, j);
    args->params[j] = ruby_strdup(StringValueCStr(entry));
    RB_GC_GUARD(entry);
  }

  return Qnil;
}

static void
_noko_xslt_stylesheet_free_params(const char **params, long param_len)
{
  for (long j = 0; j < param_len; j++) {
    ruby_xfree(DISCARD_CONST_QUAL(char *, params[j]));
  }
  ruby_xfree(params);
}

static VALUE
_noko_xslt_stylesheet_copy_document(VALUE rb_document)
{
  xmlDocPtr copy = xmlCopyDoc(noko_xml_document_unwrap(rb_document), 1);
  RB_GC_GUARD(rb_document);
  if (!copy) {
    rb_memerror();
  }
  return noko_xml_document_wrap(0, copy);
}

/*
 * call-seq:
 *   transform(document)
 *   transform(document, params = {})
 *
 * Transform an XML::Document as defined by an XSLT::Stylesheet.
 *
 * [Parameters]
 * - +document+ (Nokogiri::XML::Document) the document to be transformed.
 * - +params+ (Hash, Array) strings used as XSLT parameters.
 *
 * [Returns] Nokogiri::XML::Document
 *
 * *Example* of basic transformation:
 *
 *   xslt = <<~XSLT
 *     <xsl:stylesheet version="1.0"
 *     xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
 *
 *     <xsl:param name="title"/>
 *
 *     <xsl:template match="/">
 *       <html>
 *         <body>
 *           <h1><xsl:value-of select="$title"/></h1>
 *           <ol>
 *             <xsl:for-each select="staff/employee">
 *               <li><xsl:value-of select="employeeId"></li>
 *             </xsl:for-each>
 *           </ol>
 *         </body>
 *       </html>
 *     </xsl:stylesheet>
 *   XSLT
 *
 *   xml = <<~XML
 *     <?xml version="1.0"?>
 *     <staff>
 *       <employee>
 *         <employeeId>EMP0001</employeeId>
 *         <position>Accountant</position>
 *       </employee>
 *       <employee>
 *         <employeeId>EMP0002</employeeId>
 *         <position>Developer</position>
 *       </employee>
 *     </staff>
 *   XML
 *
 *   doc = Nokogiri::XML::Document.parse(xml)
 *   stylesheet = Nokogiri::XSLT.parse(xslt)
 *
 * ⚠️️ Note that the +h1+ element is empty because no param has been provided!
 *
 *   stylesheet.transform(doc).to_xml
 *   # => "<html><body>\n" +
 *   #    "<h1></h1>\n" +
 *   #    "<ol>\n" +
 *   #    "<li>EMP0001</li>\n" +
 *   #    "<li>EMP0002</li>\n" +
 *   #    "</ol>\n" +
 *   #    "</body></html>\n"
 *
 * *Example* of using an input parameter hash:
 *
 * ⚠️️ The title is populated, but note how we need to quote-escape the value.
 *
 *   stylesheet.transform(doc, { "title" => "'Employee List'" }).to_xml
 *   # => "<html><body>\n" +
 *   #    "<h1>Employee List</h1>\n" +
 *   #    "<ol>\n" +
 *   #    "<li>EMP0001</li>\n" +
 *   #    "<li>EMP0002</li>\n" +
 *   #    "</ol>\n" +
 *   #    "</body></html>\n"
 *
 * *Example* using the XSLT.quote_params helper method to safely quote-escape strings:
 *
 *   stylesheet.transform(doc, Nokogiri::XSLT.quote_params({ "title" => "Aaron's List" })).to_xml
 *   # => "<html><body>\n" +
 *   #    "<h1>Aaron's List</h1>\n" +
 *   #    "<ol>\n" +
 *   #    "<li>EMP0001</li>\n" +
 *   #    "<li>EMP0002</li>\n" +
 *   #    "</ol>\n" +
 *   #    "</body></html>\n"
 *
 * *Example* using an array of XSLT parameters
 *
 * You can also use an array if you want to.
 *
 *   stylesheet.transform(doc, ["title", "'Employee List'"]).to_xml
 *   # => "<html><body>\n" +
 *   #    "<h1>Employee List</h1>\n" +
 *   #    "<ol>\n" +
 *   #    "<li>EMP0001</li>\n" +
 *   #    "<li>EMP0002</li>\n" +
 *   #    "</ol>\n" +
 *   #    "</body></html>\n"
 *
 * Or pass an array to XSLT.quote_params:
 *
 *   stylesheet.transform(doc, Nokogiri::XSLT.quote_params(["title", "Aaron's List"])).to_xml
 *   # => "<html><body>\n" +
 *   #    "<h1>Aaron's List</h1>\n" +
 *   #    "<ol>\n" +
 *   #    "<li>EMP0001</li>\n" +
 *   #    "<li>EMP0002</li>\n" +
 *   #    "</ol>\n" +
 *   #    "</body></html>\n"
 *
 * See: Nokogiri::XSLT.quote_params
 */
static VALUE
rb_xslt_stylesheet_transform(int argc, VALUE *argv, VALUE self)
{
  VALUE rb_document, rb_param, rb_error_str;
  xmlDocPtr c_document ;
  xmlDocPtr c_result_document ;
  nokogiriXsltStylesheetTuple *wrapper;
  const char **params ;
  long param_len ;
  int parse_error_occurred ;
  int state = 0;

  rb_scan_args(argc, argv, "11", &rb_document, &rb_param);
  if (NIL_P(rb_param)) { rb_param = rb_ary_new2(0L) ; }
  if (!rb_obj_is_kind_of(rb_document, cNokogiriXmlDocument)) {
    rb_raise(rb_eArgError, "argument must be a Nokogiri::XML::Document");
  }

  /* handle hashes as arguments. */
  if (T_HASH == TYPE(rb_param)) {
    rb_param = rb_funcall(rb_param, rb_intern("to_a"), 0);
    rb_param = rb_funcall(rb_param, rb_intern("flatten"), 0);
  }

  Check_Type(rb_param, T_ARRAY);

  c_document = noko_xml_document_unwrap(rb_document);
  TypedData_Get_Struct(self, nokogiriXsltStylesheetTuple, &nokogiri_xslt_stylesheet_tuple_type, wrapper);

  param_len = RARRAY_LEN(rb_param);
  params = ruby_xcalloc((size_t)param_len + 1, sizeof(char *));
  {
    // populate params under rb_protect so that a raise from StringValueCStr
    // (e.g. on a null byte) does not leak the params allocation.
    build_xslt_params_args_t args = { rb_param, param_len, params };

    rb_protect(build_xslt_params, (VALUE)&args, &state);
    if (state) {
      _noko_xslt_stylesheet_free_params(params, param_len);
      rb_jump_tag(state);
    }
  }
  params[param_len] = 0 ;

  rb_error_str = rb_str_new(0, 0);
  xmlGenericErrorFunc previous_xslt_handler = xsltGenericError;
  void *previous_xslt_context = xsltGenericErrorContext;
  xmlGenericErrorFunc previous_xml_handler = xmlGenericError;
  void *previous_xml_context = xmlGenericErrorContext;
  xsltSetGenericErrorFunc((void *)rb_error_str, xslt_generic_error_handler);
  xmlSetGenericErrorFunc((void *)rb_error_str, xslt_generic_error_handler);

  xsltTransformContextPtr c_transform_context = xsltNewTransformContext(wrapper->ss, c_document);
  if (c_transform_context && !c_transform_context->_private &&
      xsltNeedElemSpaceHandling(c_transform_context) &&
      noko_xml_document_has_wrapped_blank_nodes_p(c_document)) {
    // see https://github.com/sparklemotion/nokogiri/issues/2800
    xsltFreeTransformContext(c_transform_context);
    c_transform_context = NULL;
    /* Extension callbacks may retain nodes from the copy after the transform finishes. */
    rb_document = rb_protect(_noko_xslt_stylesheet_copy_document, rb_document, &state);
    if (!state) {
      c_document = noko_xml_document_unwrap(rb_document);
      c_transform_context = xsltNewTransformContext(wrapper->ss, c_document);
    }
  }

  c_result_document = NULL;
  if (c_transform_context) {
    if (!c_transform_context->_private) {
      c_result_document = xsltApplyStylesheetUser(wrapper->ss, c_document, params,
                          NULL, NULL, c_transform_context);
    }
    state = (int)(intptr_t)c_transform_context->_private;
    xsltFreeTransformContext(c_transform_context);
  }

  _noko_xslt_stylesheet_free_params(params, param_len);

  xsltSetGenericErrorFunc(previous_xslt_context, previous_xslt_handler);
  xmlSetGenericErrorFunc(previous_xml_context, previous_xml_handler);
  RB_GC_GUARD(self);
  RB_GC_GUARD(rb_document);

  if (state) {
    xmlFreeDoc(c_result_document);
    rb_jump_tag(state);
  }

  parse_error_occurred = (Qfalse == rb_funcall(rb_error_str, rb_intern("empty?"), 0));

  if (parse_error_occurred) {
    xmlFreeDoc(c_result_document);
    rb_exc_raise(rb_exc_new3(rb_eRuntimeError, rb_error_str));
  }
  if (!c_result_document) {
    rb_raise(rb_eRuntimeError, "Could not transform document");
  }

  return noko_xml_document_wrap((VALUE)0, c_result_document) ;
}

typedef struct {
  xmlXPathParserContextPtr ctxt;
  int nargs;
} xslt_method_args;

static VALUE
_noko_xslt_stylesheet_method_caller_protected(VALUE data)
{
  xslt_method_args *args = (xslt_method_args *)data;
  xmlXPathParserContextPtr ctxt = args->ctxt;
  VALUE handler;
  const char *function_name;
  xsltTransformContextPtr transform;
  const xmlChar *functionURI;

  transform = xsltXPathGetTransformContext(ctxt);
  functionURI = ctxt->context->functionURI;
  /* module data is [extension instance, nodes returned during this transform] */
  VALUE module_data = (VALUE)xsltGetExtData(transform, functionURI);
  if (transform->_private) {
    return Qnil;
  }
  handler = rb_ary_entry(module_data, 0);
  function_name = (const char *)(ctxt->context->function);

  Nokogiri_marshal_xpath_funcall_and_return_values(
    ctxt,
    args->nargs,
    handler,
    (const char *)function_name,
    rb_ary_entry(module_data, 1)
  );
  return Qnil;
}

static void
method_caller(xmlXPathParserContextPtr ctxt, int nargs)
{
  xsltTransformContextPtr transform = xsltXPathGetTransformContext(ctxt);
  if (!transform->_private) {
    xslt_method_args args = { ctxt, nargs };
    int state = 0;
    rb_protect(_noko_xslt_stylesheet_method_caller_protected, (VALUE)&args, &state);
    if (state) {
      transform->_private = (void *)(intptr_t)state;
    }
  }
  if (transform->_private) {
    transform->state = XSLT_STATE_STOPPED;
    ctxt->error = XPATH_EXPR_ERROR;
  }
}

typedef struct {
  xsltTransformContextPtr ctxt;
  const xmlChar *uri;
} xslt_init_args;

static VALUE
_noko_xslt_stylesheet_init_func_protected(VALUE data)
{
  xslt_init_args *init_args = (xslt_init_args *)data;
  xsltTransformContextPtr ctxt = init_args->ctxt;
  const xmlChar *uri = init_args->uri;
  VALUE modules = rb_iv_get(mNokogiriXslt, "@modules");
  VALUE obj = rb_hash_aref(modules, rb_str_new2((const char *)uri));
  VALUE args = { Qfalse };
  VALUE methods = rb_funcall(obj, rb_intern("instance_methods"), 1, args);
  VALUE inst;
  nokogiriXsltStylesheetTuple *wrapper;
  int i;

  for (i = 0; i < RARRAY_LEN(methods); i++) {
    VALUE method_name = rb_obj_as_string(rb_ary_entry(methods, i));
    xsltRegisterExtFunction(
      ctxt,
      (unsigned char *)StringValueCStr(method_name),
      uri,
      method_caller
    );
  }

  TypedData_Get_Struct(
    (VALUE)ctxt->style->_private,
    nokogiriXsltStylesheetTuple,
    &nokogiri_xslt_stylesheet_tuple_type,
    wrapper
  );
  inst = rb_class_new_instance(0, NULL, obj);
  VALUE module_data = rb_ary_new_from_args(2, inst, rb_ary_new());
  rb_ary_push(wrapper->func_instances, module_data);

  return module_data;
}

static void *
initFunc(xsltTransformContextPtr ctxt, const xmlChar *uri)
{
  if (ctxt->_private) {
    return NULL;
  }
  xslt_init_args args = { ctxt, uri };
  int state = 0;
  VALUE module_data = rb_protect(_noko_xslt_stylesheet_init_func_protected, (VALUE)&args, &state);
  if (state) {
    /* Delay Ruby's nonlocal exit until libxslt has released the transform context. */
    ctxt->_private = (void *)(intptr_t)state;
    ctxt->state = XSLT_STATE_STOPPED;
    return NULL;
  }
  return (void *)module_data;
}

static void
shutdownFunc(xsltTransformContextPtr ctxt,
             const xmlChar *uri, void *data)
{
  nokogiriXsltStylesheetTuple *wrapper;

  TypedData_Get_Struct(
    (VALUE)ctxt->style->_private,
    nokogiriXsltStylesheetTuple,
    &nokogiri_xslt_stylesheet_tuple_type,
    wrapper
  );

  /* A nested transform shuts down only its own instances. */
  for (long i = 0; i < RARRAY_LEN(wrapper->func_instances); i++) {
    if (rb_ary_entry(wrapper->func_instances, i) == (VALUE)data) {
      rb_ary_delete_at(wrapper->func_instances, i);
      break;
    }
  }
}

/* docstring is in lib/nokogiri/xslt.rb */
static VALUE
rb_xslt_s_register(VALUE self, VALUE uri, VALUE obj)
{
  VALUE modules = rb_iv_get(self, "@modules");
  if (NIL_P(modules)) {
    rb_raise(rb_eRuntimeError, "internal error: @modules not set");
  }

  rb_hash_aset(modules, uri, obj);
  xsltRegisterExtModule(
    (unsigned char *)StringValueCStr(uri),
    initFunc,
    shutdownFunc
  );
  return self;
}

void
noko_init_xslt_stylesheet(void)
{
  rb_define_singleton_method(mNokogiriXslt, "register", rb_xslt_s_register, 2);
  rb_iv_set(mNokogiriXslt, "@modules", rb_hash_new());

  cNokogiriXsltStylesheet = rb_define_class_under(mNokogiriXslt, "Stylesheet", rb_cObject);

  rb_undef_alloc_func(cNokogiriXsltStylesheet);

  rb_define_singleton_method(cNokogiriXsltStylesheet, "parse_stylesheet_doc", parse_stylesheet_doc, 1);
  rb_define_method(cNokogiriXsltStylesheet, "serialize", rb_xslt_stylesheet_serialize, 1);
  rb_define_method(cNokogiriXsltStylesheet, "transform", rb_xslt_stylesheet_transform, -1);
}
