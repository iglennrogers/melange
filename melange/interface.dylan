documented: #t
module: define-interface
copyright: Copyright (C) 1994, Carnegie Mellon University
	   All rights reserved.
	   This code was produced by the Gwydion Project at Carnegie Mellon
	   University.  If you are interested in using this code, contact
	   "Scott.Fahlman@cs.cmu.edu" (Internet).
rcs-header: $Header: 

//======================================================================
//
// Copyright (c) 1994  Carnegie Mellon University
// All rights reserved.
//
//======================================================================

//======================================================================
// interface.dylan contains the complete contents of module
// "define-interface".  This module provides the top level "program" for
// mindy-Melange.  It parses "interface definition" files (with a bit of help
// from "int-lexer" and "int-parse") and writes out Dylan code files (as well
// as possible auxiliary definition files), calling routines from "c-parse"
// and "c-declarations" to do most of the work.
//======================================================================

define module define-interface
  // From Dylan
  use dylan;
  use extensions;		// required for "main" (as well as key-exists?)

  // From string-extensions
  use regular-expressions;
  use substring-search;
  use character-type;

  // From streams
  use streams;
  use standard-io;

  // local packages
  use int-lexer;
  use int-parse, rename: {rename => renames};
  use c-lexer, import: {include-path};
  use c-declarations,
    rename: {parse => c-parse, <parse-state> => <c-parse-state>};
  use name-mappers;
end module define-interface;

//----------------------------------------------------------------------
// Routines to scan the interface file for "define interface" forms.
//----------------------------------------------------------------------

// Create boyer-moore search engine for "define".  This should allow us to
// scan for define interface clauses very quickly.  (We can't just search for
// "define interface", since there may be variable numbers of spaces between
// the words.
//
define constant match-define = make-substring-positioner("define");

// Check to see whether the specified "long" (sub-)string begins with the
// short string.  This routine should probably be in string-extensions
// somewhere, but it isn't yet.
//
define method is-prefix?
    (short :: <string>, long :: <string>, #key start = 0)
 => (result :: <boolean>);
  if (size(short) > size(long) - start)
    #f;
  else
    block (return)
      for (short-char in short,
	   index from start)
	if (short-char ~= long[index]) return(#f) end if;
      end for;
      #t;
    end block;
  end if;
end method is-prefix?;

// Returns the number of contiguous whitespace characters which can be found
// starting at the given position in "string".
//
define method count-whitespace
    (string :: <string>, position :: <integer>) => (count :: <integer>);
  for (index from position below size(string),
       while: whitespace?(string[index]))
  finally
    index - position;
  end for;
end method count-whitespace;

// Reads the entire contents of "in-stream" and scans for "define interface"
// form.  Any text which is not in such a form is written to "out-stream"
// verbatim, while the contents of the "define interface" forms are passed
// (along with "out-stream") to "process-define-interface" which will do all
// the interesting work.
//
define method process-interface-file
    (in-file :: <string>, out-stream :: <stream>, #key verbose) => ();
  let in-stream = make(<file-stream>, name: in-file);
  let input-string = read-as(<byte-string>, in-stream, to-eof?: #t);
  let sz = input-string.size;
  
  local method try-define (position :: <integer>) => ();
	  let new-position = match-define(input-string, start: position);
	  write(input-string, out-stream, start: position,
		end: new-position | sz);
	  if (new-position)
	    let index = new-position + 6;
	    let space-count = count-whitespace(input-string, index);
	    if (space-count > 0
		  & is-prefix?("interface", input-string,
			       start: index + space-count))
	      let newer-position
		= process-define-interface(in-file, input-string,
					   new-position, out-stream,
					   verbose: verbose);
	      if (newer-position < sz) try-define(newer-position) end if;
	    else
	      write(input-string, out-stream, start: new-position,
		    end: index + space-count);
	      try-define(index + space-count);
	    end if;
	  end if;
	end method try-define;
  try-define(0);
  if (verbose) write-line("", *standard-output*) end if;
end method process-interface-file;

//----------------------------------------------------------------------
// Support routines for "process-define-interface"
//----------------------------------------------------------------------

// Type dependent handling for "clauses" within the define interface.  These
// include "function", "struct", "union", "pointer", "variable" and "constant"
// clauses.  "#include" clauses are handled directly by
// "process-define-interface".
//
// These methods may retrieve and annotate declarations from "c-state", thus
// modifying the behavior of "write-declaration".
//
define generic process-clause
    (clause :: <clause>, state :: <parse-state>, c-state :: <c-parse-state>)
 => ();

//------------------------------------------------------------------------

// Handles the different types of mapping: type renaming, type mapping, and
// type equation.  "find-decl" should be a function which maps a string into a
// declaration -- likely this will be a curried call to "parse-type" or
// "find-slot". 
//
define method process-mappings
    (options :: <container-options>, find-decl :: <function>) => ();
  // Note that duplicate renamings will be accepted the last rename/equate for
  // a type will supersede all others.
  for (mapping in options.renames)
    rename(mapping.head.find-decl, as(<string>, mapping.tail));
  end for;
  for (mapping in options.mappings)
    remap(mapping.head.find-decl, as(<string>, mapping.tail));
  end for;
  for (mapping in options.equates)
    let decl = mapping.head.find-decl;
    equate(decl, as(<string>, mapping.tail));
  end for;
end method process-mappings;

// Processes top-level "import:" and "exclude:" options, producing an
// "imports" table to be passed to declaration-closure.  The table is keyed by
// the declaration itself and will contain either #t or a renaming for every
// explicitly imported declaration, #f for every explicitly excluded
// declarations, and be undefined for others.  "Import-all?" can be used to
// determine whether to import declarations which are not explictly named.
//
// "find-decl" should be a mapping from strings to declarations -- likely a
// curried call to either "parse-type" or "find-slot".
//
define method process-imports
    (options :: <container-options>, find-decl :: <function>)
 => (imports :: <explicit-key-collection>, import-all? :: <boolean>);

  let import-list = options.imports;
  let imports :: <explicit-key-collection> = make(<object-table>);
  let import-all? :: <boolean> = import-list.empty?;
    
  for (elem in import-list)
    if (instance?(elem, <sequence>))
      for (import in elem)
	if (instance?(import, <pair>))
	  imports[import.head.find-decl] := as(<string>, import.tail);
	else
	  imports[import.find-decl] := #t;
	end if;
      end for;
    else
      import-all? := #t;
    end if;
  end for;
  do(method (name) imports[name.find-decl] := #f end method, options.exclude);
  values(imports, import-all?);
end method process-imports;

// Given one or more <container-options>s, merge them all together (with
// conflicts resolving to the first <container-option> which gives a value for
// the particular field) and fill in defaults for any unspecified fields.
// 
define method merge-container-options
    (first :: <container-options>, #rest rest)
 => (mapper :: <function>, prefix :: <string>, read-only :: <boolean>,
     sealing :: <string>);
  let mapper = first.name-mapper;
  let pre = first.prefix;
  let rd-only = first.read-only;
  let sealing = first.seal-string;
  for (next in rest)
    if (mapper == undefined) mapper := next.name-mapper end if;
    if (pre == undefined) pre := next.prefix end if;
    if (rd-only == undefined) rd-only := next.read-only end if;
    if (sealing == undefined) sealing := next.seal-string end if;
  end for;
  if (mapper == undefined)
    mapper := #"minimal-name-mapping-with-structure-prefix";
  end if;
  if (pre == undefined) pre := "" end if;
  if (rd-only == undefined) rd-only := #f end if;
  if (sealing == undefined) sealing := "sealed" end if;
  values(curry(map-name, mapper), pre, rd-only, sealing);
end method merge-container-options;

//----------------------------------------------------------------------
// Type specific methods for "process-clause".
//----------------------------------------------------------------------

define method process-clause
    (clause :: <function-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (~instance?(decl, <function-declaration>))
    error("Function clause names a non-function: %s", clause.name);
  end if;
  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"equate-result" =>
	equate(decl.find-result, body);
      #"map-result" =>
	remap(decl.find-result, body);
      #"ignore-result" =>
	if (body) decl.find-result.ignored? := #t end if;
      #"equate-arg" =>
	equate(find-parameter(decl, body.head), body.tail);
      #"map-arg" =>
	remap(find-parameter(decl, body.head), body.tail);
      otherwise =>
	find-parameter(decl, body).argument-direction := tag;
    end select;
  end for;
end method process-clause;

define method process-clause
    (clause :: <variable-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (~instance?(decl, <variable-declaration>))
    error("Variable clause names a non-variable: %s", clause.name);
  end if;
  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"setter" => if (body) decl.setter := body else decl.read-only := #t end;
      #"getter" => decl.getter := body;
      #"read-only" => decl.read-only := body;
      #"seal" => decl.sealed-string := body;
      #"equate" => equate(decl, body);
      #"map" => remap(decl, body);
    end select;
  end for;
end method process-clause;

define method process-clause
    (clause :: <constant-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (~instance?(decl, <constant-declaration>))
    error("Constant clause names a non-constant: %s", clause.name);
  end if;
  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"value" => decl.constant-value := body;
    end select;
  end for;
end method process-clause;

define method process-clause
    (clause :: <struct-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (instance?(decl, <typedef-declaration>)) decl := true-type(decl) end if; 
  if (~instance?(decl, <struct-declaration>))
    error("Struct clause names a non-struct: %s", clause.name);
  end if;

  let (#rest opts) = merge-container-options(clause.container-options,
					     state.container-options);
  apply(apply-container-options, decl, opts);

  let find-decl = curry(find-slot, decl);
  process-mappings(clause.container-options, find-decl);
  let (imports, import-all?) = process-imports(clause.container-options,
					       find-decl);
  exclude-slots(decl, imports, import-all?);
  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"superclass" =>
	let supers
	  = if (member?("<statically-typed-pointer>", body, test: \=))
	      body
	    else
	      concatenate(body, #("<statically-typed-pointer>"));
	    end if;
	decl.superclasses := supers;
    end select;
  end for;
end method process-clause;

define method process-clause
    (clause :: <union-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (instance?(decl, <typedef-declaration>)) decl := true-type(decl) end if; 
  if (~instance?(decl, <union-declaration>))
    error("Union clause names a non-union: %s", clause.name);
  end if;
  let (#rest opts) = merge-container-options(clause.container-options,
					     state.container-options);
  apply(apply-container-options, decl, opts);

  let find-decl = curry(find-slot, decl);
  process-mappings(clause.container-options, find-decl);
  let (imports, import-all?) = process-imports(clause.container-options,
					       find-decl);
  exclude-slots(decl, imports, import-all?);
  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"superclass" =>
	let supers = if (member?("<statically-typed-pointer>", body))
		       body
		     else
		       concatenate(body, #("<statically-typed-pointer>"));
		     end if;
	decl.superclasses := supers;
    end select;
  end for;
end method process-clause;

define method process-clause
    (clause :: <pointer-clause>, state :: <parse-state>,
     c-state :: <c-parse-state>)
 => ();
  let decl = parse-type(clause.name, c-state);
  if (instance?(decl, <pointer-declaration>)) decl := true-type(decl) end if; 
  if (~instance?(decl, union(<pointer-declaration>, <vector-declaration>)))
    error("Pointer clause names a non-pointer: %s", clause.name);
  end if;

  for (option in clause.options)
    let tag = option.head;
    let body = option.tail;
    select (tag)
      #"superclass" =>
	if (instance?(decl, <vector-declaration>))
	  let supers = concatenate(body, list(decl.pointer-equiv.dylan-name,
					      "<c-vector>",
					      "<statically-typed-pointer>"));
	  decl.superclasses := remove-duplicates!(supers);
	else
	  let supers = if (member?("<statically-typed-pointer>", body))
			 body;
		       else
			 concatenate(body, #("<statically-typed-pointer>"));
		       end if;
	  decl.superclasses := supers;
	end if;
    end select;
  end for;
end method process-clause;

//----------------------------------------------------------------------
// High level processing routines for interface definitions
//----------------------------------------------------------------------

// Process-parse-state does all necessary processing for the required
// "#include" clause and invokes process clause for all other clauses in the
// interface defintion.
//
// When all of the clauses have been processed, we end up with a list of
// annotated declarations.  These are passed, along with out-stream, to
// write-declaration for final processing.
//
define method process-parse-state
    (state :: <parse-state>, out-stream :: <stream>, #key verbose) => ();
  if (~state.include-file)
    parse-error(state, "Missing #include in 'define interface'");
  end if;
  let c-state
    = c-parse(state.include-file,
	      defines: state.macro-defines, undefines: state.macro-undefines,
	      verbose: verbose);

  // The ordering of some of the following steps is important.  We must
  // process all of the clauses before doing apply-options so that any
  // rename, etc. options will preempt the "default" values computed during
  // apply-options.  Apply-options must be also be called before
  // write-declaration but after declaration-closure, since each of these
  // depends upon the results of the last.

  let find-decl = rcurry(parse-type, c-state);
  process-mappings(state.container-options, find-decl);
  do(rcurry(process-clause, state, c-state), state.clauses);

  let (imports, import-all?) = process-imports(state.container-options,
					       find-decl);
  let decls = declaration-closure(c-state, imports, import-all?);
  let (#rest opts) = merge-container-options(state.container-options);
  for (decl in decls) apply(apply-options, decl, opts) end for;

  let load-string = write-file-load(state.object-files, decls, out-stream);
  write-mindy-includes(state.mindy-include-file, decls);
  do(rcurry(write-declaration, load-string, out-stream), decls);
end method process-parse-state;
  
// Process-define-interface simply calls the parser in int-parse to decipher
// the "define interface" and then call "process-parse-state" to annotate and
// write out the declarations.  It returns the character position of the first
// token after the interface definition.
//
define method process-define-interface
    (file-name :: <string>, string :: <string>, start :: <integer>,
     out-stream :: <stream>,
     #key verbose)
 => (end-position :: <integer>);
  let tokenizer = make(<tokenizer>, source-string: string,
		       source-file: file-name, start: start);
  let state = make(<parse-state>, tokenizer: tokenizer);
  // If there is a problem with the parse, it will simply signal an error
  parse(state);
  process-parse-state(state, out-stream, verbose: verbose);
  // The tokenizer will be set at the next token after the "define
  // interface".  We can't just call tokenizer.position since there may have
  // been an "unget-token" call.
  get-token(tokenizer).position;
end method process-define-interface;

//----------------------------------------------------------------------
// The main program
//----------------------------------------------------------------------

// Processes all "interface file"s specified on the command line, writing the
// results to *standard-output*.  The user may also specify additional
// "include" directories by means of a "-Idirectory" switch.
//
// If no argument are specified, we drop into the debugger.  This is quite
// useful for testing purposes, but when we hit the final release we will want
// to print out a "help" line instead.
//
define method main (program, #rest args)
//define method main (program-name :: <string>, #rest args)
  let in-file = #f;
  let out-file = #f;
  let verbose = #f;

  for (arg in args)
    if (arg = "-v")
      verbose := #t;
    elseif (is-prefix?("-I", arg))
      push-last(include-path, copy-sequence(arg, start: 2));
    elseif (arg.first == '-')
      error("Undefined switch -- \"%s\"", arg);
    else
      case
	in-file & out-file =>
	  error("Too many args.");
	in-file =>
	  out-file := make(<file-stream>, name: arg, direction: #"output");
	otherwise =>
	  in-file := arg;
      end case;
    end if;
  end for;

  if (in-file)
    process-interface-file(in-file, out-file | *standard-output*,
			   verbose: verbose);
  else
    break("No arguments -- invoking debugger.");
  end if;
end method main;
