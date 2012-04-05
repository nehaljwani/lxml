# support for Schematron validation
cimport schematron

class SchematronError(LxmlError):
    u"""Base class of all Schematron errors.
    """
    pass

class SchematronParseError(SchematronError):
    u"""Error while parsing an XML document as Schematron schema.
    """
    pass

class SchematronValidateError(SchematronError):
    u"""Error while validating an XML document with a Schematron schema.
    """
    pass

################################################################################
# Schematron

cdef class Schematron(_Validator):
    u"""Schematron(self, etree=None, file=None)
    A Schematron validator.

    Pass a root Element or an ElementTree to turn it into a validator.
    Alternatively, pass a filename as keyword argument 'file' to parse from
    the file system.

    Schematron is a less well known, but very powerful schema language.  The main
    idea is to use the capabilities of XPath to put restrictions on the structure
    and the content of XML documents.  Here is a simple example::

      >>> schematron = etree.Schematron(etree.XML('''
      ... <schema xmlns="http://www.ascc.net/xml/schematron" >
      ...   <pattern name="id is the only permited attribute name">
      ...     <rule context="*">
      ...       <report test="@*[not(name()='id')]">Attribute
      ...         <name path="@*[not(name()='id')]"/> is forbidden<name/>
      ...       </report>
      ...     </rule>
      ...   </pattern>
      ... </schema>
      ... '''))

      >>> xml = etree.XML('''
      ... <AAA name="aaa">
      ...   <BBB id="bbb"/>
      ...   <CCC color="ccc"/>
      ... </AAA>
      ... ''')

      >>> schematron.validate(xml)
      0

      >>> xml = etree.XML('''
      ... <AAA id="aaa">
      ...   <BBB id="bbb"/>
      ...   <CCC/>
      ... </AAA>
      ... ''')

      >>> schematron.validate(xml)
      1

    Schematron was added to libxml2 in version 2.6.21.  Before version 2.6.32,
    however, Schematron lacked support for error reporting other than to stderr.
    This version is therefore required to retrieve validation warnings and
    errors in lxml.
    """
    cdef schematron.xmlSchematron* _c_schema
    cdef xmlDoc* _c_schema_doc
    def __cinit__(self):
        self._c_schema = NULL
        self._c_schema_doc = NULL

    def __init__(self, etree=None, *, file=None):
        cdef _Document doc
        cdef _Element root_node
        cdef xmlNode* c_node
        cdef char* c_href
        cdef schematron.xmlSchematronParserCtxt* parser_ctxt
        _Validator.__init__(self)
        if not config.ENABLE_SCHEMATRON:
            raise SchematronError, \
                u"lxml.etree was compiled without Schematron support."
        if etree is not None:
            doc = _documentOrRaise(etree)
            root_node = _rootNodeOrRaise(etree)
            self._c_schema_doc = _copyDocRoot(doc._c_doc, root_node._c_node)
            self._error_log.connect()
            parser_ctxt = schematron.xmlSchematronNewDocParserCtxt(
                self._c_schema_doc)
        elif file is not None:
            filename = _getFilenameForFile(file)
            if filename is None:
                # XXX assume a string object
                filename = file
            filename = _encodeFilename(filename)
            self._error_log.connect()
            parser_ctxt = schematron.xmlSchematronNewParserCtxt(_cstr(filename))
        else:
            raise SchematronParseError, u"No tree or file given"

        if parser_ctxt is NULL:
            self._error_log.disconnect()
            if self._c_schema_doc is not NULL:
                tree.xmlFreeDoc(self._c_schema_doc)
                self._c_schema_doc = NULL
            python.PyErr_NoMemory()
            return

        self._c_schema = schematron.xmlSchematronParse(parser_ctxt)
        self._error_log.disconnect()

        schematron.xmlSchematronFreeParserCtxt(parser_ctxt)
        if self._c_schema is NULL:
            raise SchematronParseError(
                u"Document is not a valid Schematron schema",
                self._error_log)

    def __dealloc__(self):
        schematron.xmlSchematronFree(self._c_schema)
        if _LIBXML_VERSION_INT >= 20631:
            # earlier libxml2 versions may have freed the document in
            # xmlSchematronFree() already, we don't know ...
            if self._c_schema_doc is not NULL:
                tree.xmlFreeDoc(self._c_schema_doc)

    def __call__(self, etree):
        u"""__call__(self, etree)

        Validate doc using Schematron.

        Returns true if document is valid, false if not."""
        cdef _Document doc
        cdef _Element root_node
        cdef xmlDoc* c_doc
        cdef schematron.xmlSchematronValidCtxt* valid_ctxt
        cdef int ret
        cdef int options

        assert self._c_schema is not NULL, "Schematron instance not initialised"
        doc = _documentOrRaise(etree)
        root_node = _rootNodeOrRaise(etree)

        if _LIBXML_VERSION_INT >= 20632 and \
                schematron.XML_SCHEMATRON_OUT_ERROR != 0:
            options = schematron.XML_SCHEMATRON_OUT_ERROR
        else:
            options = schematron.XML_SCHEMATRON_OUT_QUIET
            # hack to switch off stderr output
            options = options | schematron.XML_SCHEMATRON_OUT_XML

        valid_ctxt = schematron.xmlSchematronNewValidCtxt(
            self._c_schema, options)
        if valid_ctxt is NULL:
            return python.PyErr_NoMemory()

        if _LIBXML_VERSION_INT >= 20632:
            schematron.xmlSchematronSetValidStructuredErrors(
                valid_ctxt, _receiveError, <void*>self._error_log)
        else:
            self._error_log.connect()
        c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
        with nogil:
            ret = schematron.xmlSchematronValidateDoc(valid_ctxt, c_doc)
        _destroyFakeDoc(doc._c_doc, c_doc)
        if _LIBXML_VERSION_INT < 20632:
            self._error_log.disconnect()

        schematron.xmlSchematronFreeValidCtxt(valid_ctxt)

        if ret == -1:
            raise SchematronValidateError(
                u"Internal error in Schematron validation",
                self._error_log)
        if ret == 0:
            return True
        else:
            return False
