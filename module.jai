/*
    IMJSON -- An "immediate-mode" JSON parser inspired by TSoding's "jimp"
    
    This module makes heavy use of macros and for expansions to make parsing JSON very simple and clean.
    
    Each iterator points to its parent iterator, allowing one to traverse up current document structure when needed (for example, when reporting errors).
    Each iterator also points to the base Parser struct, which acts as a sort of general context for parsing.
    One of the nice things about this method of parsing is that it requires absolutely no heap allocations, since all of the iterators are stored on the stack.
    
    Object and array for expansions will lazily parse the fields within, creating an Iterator for each field.
    The parse_object and parse_array procs will check the type and identifier on the Iterator, and will 
    
    
    It may seem a bit silly that we have separate types for the different iterators (as well as a union version), 
    since Object_Iterator and Array_Iterator currently don't actually contain any unique members, 
    but we need these distinct types in order to define separate for expansions for objects and arrays.
    
    I suppose we could instead just use named iterators for object/array.
    perhaps after I get things working we try that out and see if it feels better or significantly reduces code size
        so far the function-call style I think looks nicer, expecially if we want to name the iterator
        however, using the named iterator proc style could remove the footgun that is writing `if parse_object` instead of `for parse_object`
            can't actually do the named iterator style since we need to pass other parameters (expectexd identifier, flags) to the parse_object proc
            and we also don't really want to do normal macro style instead of for expansion because there's not such an easy way to expose the iterators to the inner code (or rename them, for that matter)
    
    This does make me wish there was something like a `do` keyword for `for`-style macros that need other parameters
    and this `do` can be followed with a else/then block which the macro can handle, which would be helpful here as we could attach success/fail case code 
    would also be nice if some macro could be marked explicitly as a `do` so that it cannot be called like a regular macro, preventing the accidental use in an `if`
    
    
    In order to prevent duplicated checks for fields which have already been parsed, 
    we would like that the parse_xxx procs each contain some internal state variables
    but we cannot do this because there is no 'static' specifier in Jai...
*/


Parser :: struct {
    file:   string; // does not get modified while parsing
    lexer:  Lexer;
}

init_parser :: (parser: *Parser, file: string, file_path := "") {
    parser.file = file;
    init_lexer(*parser.lexer, file, file_path);   
}

get_root :: (parser: *Parser) -> Object_Iterator {
    iterator: Object_Iterator;
    iterator.parser = parser;
    iterator.flags  = .IS_ROOT;
    return iterator;
}

Iterator_Union :: union {
    using #as base: Iterator;
    field:  Field_Iterator;
    object: Object_Iterator;
    array:  Array_Iterator;
}

Iterator :: struct {
    Iterator_Type :: enum { UNINITIALIZED :: 0; FIELD; OBJECT; ARRAY; };
    
    iterator_type:  Iterator_Type;
    parser:         *Parser;
    parent:         *Iterator;
    identifier:     string;
    location:       Source_Code_Location;
    
    flags:         Flags;
    Flags :: enum_flags { IS_ROOT; HANDLED; ERROR; };
}

iterator_next :: (parent: *Iterator) -> bool, Iterator_Union {
    lexer := *parent.parser.lexer;
    
    next: Iterator_Union;
    next.parent = parent;
    next.parser = parent.parser;
    
    if parent.iterator_type != .ARRAY {
        token := get_token(lexer);
        if token.type != .STRING {
            report_error(parent, "Expected STRING for field name, but got %. %", token.type, token.text);
            return false, .{};
        }
        next.identifier = token.text;
        next.location   = token.location;
        
        token = get_token(lexer);
        if token.type != .COLON {
            report_error(parent, "Expected COLON, but got %. %", token.type, token.text);
            return false, .{};
        }
    }
    
    token := get_token(lexer);
    if token.type == {
      case .NULL;   #through;
      case .TRUE;   #through;
      case .FALSE;  #through;
      case .NUMBER; #through;
      case .STRING;
        next.iterator_type = .FIELD;
        next.field.value = token.text;
        
      case .OBJECT_BEGIN;
        next.iterator_type = .OBJECT;
        
      case .ARRAY_BEGIN;
        next.iterator_type = .ARRAY;
        
      case;
        report_error(parent, "Unexpected % token: '%'", token.type, token.text);
        return false, .{};
    }
    next.location = ifx next.location.line_number then next.location else token.location;
    
    return true, next;
}

iterator_skip :: (iterator: *Iterator) -> bool {
    assert(iterator.flags & .HANDLED == 0);
    lexer := *iterator.parser.lexer;
    
    if iterator.iterator_type == {
      case .OBJECT;
        depth := 0;
        while 1 {
            token := get_token(lexer);
            if token.type == {
              case .EOF;
                report_error(iterator, "Unexpected EOF while scanning for end of unhandled object.");
                return false;
                
              case .ERROR;
                report_error(iterator, "Lexer error while scanning for end of unhandled object.");
                return false;
                
              case .OBJECT_BEGIN;
                depth += 1;
                
              case .OBJECT_END;
                if depth == 0 { break; }
                depth -= 1;
            }
        }
        
      case .ARRAY;
        depth := 0;
        while 1 {
            token := get_token(lexer);
            if token.type == {
              case .EOF;
                report_error(iterator, "Unexpected EOF while scanning for end of unhandled array.");
                return false;
                
              case .ERROR;
                report_error(iterator, "Lexer error while scanning for end of unhandled array.");
                return false;
                
              case .ARRAY_BEGIN;
                depth += 1;
                
              case .ARRAY_END;
                if depth == 0 { break; }
                depth -= 1;
            }
        }
    }
    
    return true;
}



// TODO: what do we do if identifier is empty, e.g. arrays? 
//       We should probably just store it_index on each Iterator as well...
append_path :: (builder: *String_Builder, iterator: *Iterator) {
    if iterator.parent {
        append_path(builder, iterator.parent);
        append(builder, "/");
    }
    append(builder, iterator.identifier);
}

get_path :: (iterator: *Iterator) -> string {
    builder: String_Builder;
    append_path(*builder, iterator);
    return builder_to_string(*builder);
}

report_error :: (using iterator: *Iterator, format: string, args: ..Any) {
    builder: String_Builder;
    
    { using iterator.location;
        if fully_pathed_filename {
            print(*builder, "%:", fully_pathed_filename);
        }
        print(*builder, "%,%: ", line_number, character_number);
    }
    
    append(*builder, "@ ");
    append_path(*builder, iterator);
    append(*builder, ": ");
    
    print(*builder, format, ..args);
    
    log(builder_to_string(*builder));
    
    iterator.flags |= .ERROR;
} @PrintLike



/*
    We can either just have a single parse_field proc which uses reflection to set the field value,
    OR we can have parse_int, parse_float, parse_string, etc which can be slightly more efficient on account of knowing what the data type is up front
    OR maybe we even just do both and see what the code looks like in either case...
    
    I will probaly do the generic version first since I already have set_value_from_string anyhow
*/

Field_Iterator :: struct(T: Type = void) #modify {
    return T == void || T.(*Type_Info).type == .ARRAY, "T must be an array type, or void if no exported 'it' is desired.";
} {
    using #as base: Iterator;
    base.iterator_type = .FIELD;
    
    value: string;
}

// Field parsing is wrapped in a macro so that we can do some funky magic.
// Mostly for the sake of error handling and doing multi-pass stuff
// The parse_object and parse_array for expansions maybe in the future get some special logic that will change how parse_field operates on a second validation pass
parse_field :: (iterator: *Iterator, identifier: string, value: Any) -> bool #expand {
    if iterator.identifier != identifier   return false;
    
    if !set_value_from_string(value, iterator.(*Field_Iterator).value) {
        report_error(iterator, "Failed to parse value of type % from string: '%'.", (*value.type).(*Type).*, iterator.(*Field_Iterator).value);
        return false;
    }
    
    iterator.flags |= .HANDLED;
    return true;
}



Object_Iterator :: struct {
    using #as base: Iterator;
    base.iterator_type = .OBJECT;
}

parse_object :: inline (iterator: *Iterator, identifier: string = "") -> *Object_Iterator {
    if iterator.iterator_type != .OBJECT 
    || iterator.identifier    != identifier  return null;
    
    return iterator.(*Object_Iterator);
}

for_expansion :: (using object_iterator: *Object_Iterator, $body: Code, for_flags: For_Flags) #expand {
    if object_iterator == null      return;
    
    if !check_object_end(object_iterator) {
        `it_index := 0;
        while 1 { defer it_index += 1;
            it_ok, it_union := iterator_next(object_iterator);
            if !it_ok  return;
            `it := (*it_union).(*Iterator);
            
            #insert body;
            
            if it.flags & .ERROR {
                object_iterator.flags |= .ERROR;
                return;
            }
            if !(it.flags & .HANDLED)  iterator_skip(it);
            
            expect_another := expect_token_type(*parser.lexer, .COMMA);
            if check_object_end(object_iterator) {
                if expect_another {
                    report_error(it, "Unexpected comma after field.");
                    return;
                }
                break;
            } else {
                if !expect_another {
                    report_error(it, "Expected a comma after field.");
                    return;
                }
            }
        }
    }
    
    object_iterator.flags |= .HANDLED;
}

check_object_end :: (using object_iterator: *Object_Iterator) -> bool { 
    if flags & .IS_ROOT  return expect_token_type(*parser.lexer, .EOF);
    return expect_token_type(*parser.lexer, .OBJECT_END);
}



Array_Iterator :: struct {
    using #as base: Iterator;
    base.iterator_type = .ARRAY;
}

parse_array :: inline (iterator: *Iterator, identifier: string = "") -> *Array_Iterator {
    if iterator.iterator_type != .ARRAY 
    || iterator.identifier    != identifier  return null;
    
    return iterator.(*Array_Iterator);
}

for_expansion :: (using array_iterator: *Array_Iterator, $body: Code, for_flags: For_Flags) #expand {
    if array_iterator == null      return;
    
    if !check_array_end(array_iterator) {
        `it_index := 0;
        while 1 { defer it_index += 1;
            it_ok, it_union := iterator_next(array_iterator);
            if !it_ok  return;
            `it := (*it_union).(*Iterator);
            
            #insert body;
            
            if it.flags & .ERROR {
                array_iterator.flags |= .ERROR;
                return;
            }
            if !(it.flags & .HANDLED)  iterator_skip(it);
            
            expect_another := expect_token_type(*parser.lexer, .COMMA);
            if check_array_end(array_iterator) {
                if expect_another {
                    report_error(it, "Unexpected comma after field.");
                    return;
                }
                break;
            } else {
                if !expect_another {
                    report_error(it, "Expected a comma after field.");
                    return;
                }
            }
        }
    }
    
    array_iterator.flags |= .HANDLED;
}

check_array_end :: (using array_iterator: *Array_Iterator) -> bool { 
    return expect_token_type(*parser.lexer, .ARRAY_END);
}


/*
    Notes for myself, future implementation:
    
    Tsoding makes a good point about objects with this kind of structure:
    {
        type: "Foo",
        value: { ... }
    }
    where the value object needs to be parsed differently depending on the type.
    if the value object is ordered before the value in the parent object, then we have a problem.
    simple solution is just to say that the type must always come first, but that's probably technically not compliant with some JSON spec that says objects must be parsed in an order-independent way
    perhaps we could implement some special flag on parse_field that tells the parser to scan ahead for this field in the object, that way if it is present we get its value right away or report an error
    This scanning ahead could be more costly but at least it would be an option to get around this scenario
    
    We could can also add easy flags for user to state that certain fields are mandatory and must be present
        this will be a bit more tricky to implement since we can only check that all required fields were found in an object when exiting the object's scope
        may require some allocations in order to make this work, or we can instead do a second pass after we are finished parsing an object to run validation code at the end
        this is getting very magical though...
*/

#scope_module

#import "Basic";
#import "File";
#import "String";
#import "Unicode";

whitespace_chars  :: " \t\r\n";
punctuation_chars :: "{}[]:,";
whitespace_and_punctuation_chars :: #run join(whitespace_chars, punctuation_chars);

Token :: struct {
    type:       Token_Type;
    text:       string;
    location:   Source_Code_Location;
}

Token_Type :: enum {
    ERROR        :: -1;
    EOF          ::  0;
    
    OBJECT_BEGIN :: #char "{";
    OBJECT_END   :: #char "}";
    ARRAY_BEGIN  :: #char "[";
    ARRAY_END    :: #char "]";
    
    COLON        :: #char ":";
    COMMA        :: #char ",";
    
    NULL         :: 255 + 1;
    TRUE         :: 255 + 2;
    FALSE        :: 255 + 3;
    STRING       :: 255 + 4;
    NUMBER       :: 255 + 5;
}

Lexer :: struct {
    file: string;
    next_token:  Token;
    using location: Source_Code_Location;
}

init_lexer :: (lexer: *Lexer, file: string, file_path := "") {
    lexer.file     = file;
    lexer.location = .{ file_path, 1, 1 };
    get_token(lexer);
}

get_token :: inline (using lexer: *Lexer) -> Token {
    if next_token.type == .ERROR {
        return next_token;
    }
    
    current_token := next_token;
    next_token = lex_next_token(lexer);
    return current_token;
}

peek_token :: inline (using lexer: *Lexer) -> Token {
    return next_token;
}

// only consumes token if it was the expected type
expect_token_type :: (using lexer: *Lexer, type: Token_Type) -> bool {
    token := peek_token(lexer);
    if token.type == type {
        get_token(lexer);
        return true;
    }
    return false;
}

lex_next_token :: (using lexer: *Lexer) -> Token {
    if !skip_whitespace(lexer)  return .{ .EOF, "", lexer.location };
    token_location := lexer.location;
    
    return_error :: (message: string = "") #expand { `return .{ .ERROR, message, token_location }; }
    
    // single-character tokens
    if file[0] == {
      case "{";  advance(lexer);  return .{ .OBJECT_BEGIN, "{", token_location };
      case "}";  advance(lexer);  return .{ .OBJECT_END,   "}", token_location };
      case "[";  advance(lexer);  return .{ .ARRAY_BEGIN,  "[", token_location };
      case "]";  advance(lexer);  return .{ .ARRAY_END,    "]", token_location };
      case ":";  advance(lexer);  return .{ .COLON,        ":", token_location };
      case ",";  advance(lexer);  return .{ .COMMA,        ",", token_location };
    }
    
    // identifier-like tokens 
    if begins_with(file, "true" ) { advance(lexer, 4); return .{ .TRUE,  "true",  token_location }; }
    if begins_with(file, "false") { advance(lexer, 5); return .{ .FALSE, "false", token_location }; }
    if begins_with(file, "null" ) { advance(lexer, 4); return .{ .NULL,  "null",  token_location }; }
    
    // try lexing a number
    {
        ok, text := lex_number(lexer);
        if !ok   return_error(text);
        if text  return .{ .NUMBER, text, token_location };
    }
    
    // try lexing a string
    if file[0] == "\"" { 
        quote_char := file[0];
        
        if !advance(lexer)  return_error("Unexpected EOF while parsing string.");
        start := file.data;
        
        while file[0] != quote_char {
            if file[0] == "\\" {
                if !advance(lexer)  return_error("Unexpected EOF while parsing escape sequence.");
                
                if is_any(file[0], "\"\\/bfnrt") {
                    if !advance(lexer)  return_error("Unexpected EOF while parsing escape sequence.");
                } else if file[0] == "u" {
                    if !advance(lexer)     return_error("Unexpected EOF while parsing escape sequence.");
                    for 0..3 {
                        if !is_digit(file[0])  return_error("Unexpected character while parsing escape sequence.");
                        if !advance(lexer)     return_error("Unexpected EOF while parsing escape sequence.");
                    }
                } else {
                    return_error("Unexpected character while parsing escape sequence.");
                }
            } else {
                codepoint, len, result := character_utf8_to_utf32(file.data, file.count);
                if result != .CONVERSION_OK {
                    return_error("utf8 decode error while parsing string");
                }
                if codepoint < 0x20 || codepoint > 0x10FFFF {
                    return_error("invalid character while parsing string");
                }
                if !advance(lexer, len)  return_error("Unexpected EOF while parsing string.");
            }
        }
        
        text := string.{ file.data - start, start };
        advance(lexer);
        return .{ .STRING, text, token_location };
    }
    
    return_error("Unexpected character encountered.");
}

// returns false on EOF
skip_whitespace :: (using lexer: *Lexer) -> bool {
    if !file  return false;
    while is_any(file[0], whitespace_chars) {
        if !advance(lexer) return false;
    }
    return true;
}

// advances UP TO the amount specified, returns false on EOF
advance :: inline (using lexer: *Lexer, amount := 1) -> bool {
    assert(amount >= 0);
    _amount := min(amount, file.count);
    
    for 0.._amount-1 {
        if file[it] == "\n" {
            location.line_number += 1;
            location.character_number = 1;
        } else {
            location.character_number += 1;
        }
    }
    
    file.data  += _amount;
    file.count -= _amount;
    
    return file.count > 0; // return false when we hit EOF
}

lex_number :: (using lexer: *Lexer) -> bool, string {
    if !file || !(file[0] == "-" || is_digit(file[0]))  return true, "";
    
    start := file.data;
    advance(lexer);
    
    // It's dumb that we can't just have leading zeroes in JSON.
    if start.* != "0" {
        while is_digit(file[0]) && advance(lexer)  {};
    }
    
    if file {
        if file && file[0] == "." {
            if !advance(lexer)  return false, "Unexpected EOF while parsing number.";
            
            if !is_digit(file[0])  return false, "Unexpected character while parsing number, expected a digit.";
            while is_digit(file[0]) && advance(lexer)  {};
        }
        
        if file && (file[0] == "e" || file[0] == "E") {
            if !advance(lexer)  return false, "Unexpected EOF while parsing number.";
            
            if (file[0] == "+" || file[0] == "-") {
                if !advance(lexer)  return false, "Unexpected EOF while parsing number.";
            }
            
            if !is_digit(file[0])  return false, "Unexpected character while parsing number, expected a digit.";
            while is_digit(file[0]) && advance(lexer)  {};
        }
    }
    
    return true, .{ file.data - start, start };
}


// Reflection is only imported for set_value_from_string.
// You may wish to remove this import if you choose to alter the behaviour of this procedure.
Reflection :: #import "Reflection"; 

// By default, we copy strings from the source file but do not convert escape sequences.
set_value_from_string :: (any: Any, text: string, get_source_strings := false, do_convert_escape_sequences := false) -> bool {
    if any.type.type == .STRING {
        if get_source_strings {
            any.value_pointer.(*string).* = text;
        } else if do_convert_escape_sequences {
            str, ok := convert_escape_sequences(text);
            if !ok {
                free(str);
                return false;
            }
            any.value_pointer.(*string).* = str;
        } else {
            any.value_pointer.(*string).* = copy_string(text); 
        }
        return true;
    }
    return Reflection.set_value_from_string(any, text);
}

convert_escape_sequences :: (text: string) -> string, bool {
    builder: String_Builder;
    ok := convert_escape_sequences(*builder, text);
    if !ok {
        free_buffers(*builder);
        return "", false;
    }
    return builder_to_string(*builder), true;
}

convert_escape_sequences :: (builder: *String_Builder, text: string) -> bool {
    _text := text;
    while _text {
        if _text[0] == "\\" {
            ok, str, len := parse_escape_sequence(_text);
            if !ok  return false;
            append(builder, str);
            advance(*_text, len);
        } else {
            append(builder, _text[0]);
            advance(*_text, 1);
        }
    }
    return true;
}

parse_escape_sequence :: (str: string) -> success: bool, value: string, sequence_length: int {
    if str.count < 2 || str[0] != "\\" {
        return false, "", 0;
    }
    
    if str[1] == {
      case "n";   return true, "\n", 2;
      case "r";   return true, "\r", 2;
      case "t";   return true, "\t", 2;
      case "\\";  return true, "\\", 2;
      case "\"";  return true, "\"", 2;
        
      case "u";
        if str.count < 6 {
            log("Error: unexpected EOF in 16-bit unicode escape sequence: '%'", str);
            return false, "", 0;
        }
        
        codepoint: u32;
        codepoint |= ascii_hex_char_to_byte(str[5]) <<  0;
        codepoint |= ascii_hex_char_to_byte(str[4]) <<  4;
        codepoint |= ascii_hex_char_to_byte(str[3]) <<  8;
        codepoint |= ascii_hex_char_to_byte(str[2]) << 12;
        
        text := character_utf32_to_utf8(codepoint,, temp);
        return true, text, 6;
    }
    
    log("Error: invalid escape sequence beginning with: '%'", slice(str, 0, 2));
    return false, "", 0;
}

ascii_hex_char_to_byte :: (c: u8) -> u8 {
    if c >= "0" && c <= "9" then return  c - "0";
    if c >= "A" && c <= "F" then return (c - "A") + 10;
    if c >= "a" && c <= "f" then return (c - "a") + 10;
    return 0;
}

