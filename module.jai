/*
    IMJSON -- An "immediate-mode" JSON parser inspired by TSoding's "jimp"
    
    This module makes heavy use of macros and for expansions to make parsing JSON very simple and clean.
    
    Each iterator points to its parent iterator, allowing one to traverse up current document structure when needed (for example, when reporting errors).
    Each iterator also points to the base JSON_Parser struct, which acts as a sort of general context for parsing.
    One of the nice things about this method of parsing is that it requires absolutely no heap allocations, since all of the iterators are stored on the stack.
    
    Object and array for expansions will lazily parse the fields within, creating an JSON_Iterator for each field.
    The parse_object and parse_array procs will check the type and identifier on the JSON_Iterator, and will begin parsing member fields/elements if they match.
*/

JSON_Parser :: struct {
    file:   string; // does not get modified while parsing
    lexer:  Lexer;
}

init_parser :: (parser: *JSON_Parser, file: string, file_path := "") {
    parser.file = file;
    init_lexer(*parser.lexer, file, file_path);   
}

get_root :: (parser: *JSON_Parser) -> JSON_Iterator {
    iterator: JSON_Iterator;
    iterator.type   = .OBJECT;
    iterator.parser = parser;
    iterator.flags  = .IS_ROOT;
    return iterator;
}

JSON_Iterator :: struct {
    Iterator_Type :: enum { UNINITIALIZED :: 0; FIELD; OBJECT; ARRAY; };
    
    type:       Iterator_Type;
    parser:     *JSON_Parser;
    parent:     *JSON_Iterator;
    identifier: string;
    value:      string;
    location:   Source_Code_Location;
    flags:      Flags;
    
    Flags :: enum_flags { IS_ROOT; HANDLED; ERROR; };
}

iterator_next :: (parent: *JSON_Iterator) -> bool, JSON_Iterator {
    lexer := *parent.parser.lexer;
    
    next: JSON_Iterator;
    next.parent = parent;
    next.parser = parent.parser;
    
    if parent.type != .ARRAY {
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
        next.type = .FIELD;
        next.value = token.text;
        
      case .OBJECT_BEGIN;
        next.type = .OBJECT;
        
      case .ARRAY_BEGIN;
        next.type = .ARRAY;
        
      case;
        report_error(parent, "Unexpected % token: '%'", token.type, token.text);
        return false, .{};
    }
    next.location = ifx next.location.line_number then next.location else token.location;
    
    return true, next;
}

iterator_skip :: (iterator: *JSON_Iterator) -> bool {
    assert(iterator.flags & .HANDLED == 0);
    if iterator.type == {
      case .OBJECT; return skip_aggr(iterator.parser);
      case .ARRAY;  return skip_aggr(iterator.parser, IS_ARRAY = true);
    }
    return true;
}

// NOTE: We assume this can never be called on the root object. (Because why would you ever do that?)
//       If you do manually do this, it will not work right, because we don't pass is_root when calling check_object_end.
skip_aggr :: (parser: *JSON_Parser, $IS_ARRAY := false) -> bool {
    check_end :: #ifx IS_ARRAY then check_array_end else check_object_end;
    
    if !check_end(parser) {
        while 1 {
            token: Token;
            
            #if !IS_ARRAY {
                token = get_token(*parser.lexer);
                if token.type != .STRING {
                    report_error(parser, "Expected STRING for field name, but got %. %", token.type, token.text);
                    return false;
                }
                
                token = get_token(*parser.lexer);
                if token.type != .COLON {
                    report_error(parser, "Expected COLON, but got %. %", token.type, token.text);
                    return false;
                }
            }
            
            token = get_token(*parser.lexer);
            if token.type == {
              case .NULL;
              case .TRUE;
              case .FALSE;
              case .NUMBER;
              case .STRING;
                
              case .OBJECT_BEGIN;
                if !skip_aggr(parser)  return false;
                
              case .ARRAY_BEGIN;
                if !skip_aggr(parser, IS_ARRAY)  return false;
                
              case;
                report_error(parser, "Unexpected % token: '%'", token.type, token.text);
                return false;
            }
            
            expect_another := expect_token_type(*parser.lexer, .COMMA);
            is_end         := check_end(parser);
            
            if is_end {
                if expect_another {
                    report_error(parser, "Unexpected comma after field.");
                    return false;
                }
                return true;
            } else if !expect_another {
                report_error(parser, "Expected a comma after field.");
                return false;
            }
        }
    } 
    return true;
}

// TODO: what do we do if identifier is empty, e.g. arrays? 
//       We should probably just store it_index on each JSON_Iterator as well...
append_path :: (builder: *String_Builder, iterator: *JSON_Iterator) {
    if iterator.parent {
        append_path(builder, iterator.parent);
        append(builder, "/");
    }
    append(builder, iterator.identifier);
}

get_path :: (iterator: *JSON_Iterator) -> string {
    builder: String_Builder;
    append_path(*builder, iterator);
    return builder_to_string(*builder);
}

format_location :: (builder: *String_Builder, using location: Source_Code_Location) {
    if fully_pathed_filename {
        print(builder, "%:", fully_pathed_filename);
    }
    print(builder, "%,%: ", line_number, character_number);
}

// NOTE: This procedure will flag the iterator as hacing encountered an error, 
//       which will result in the termination of parsing.
report_error :: (using iterator: *JSON_Iterator, format: string, args: ..Any) {
    builder: String_Builder;
    
    iterator.flags |= .ERROR;
    
    format_location(*builder, iterator.location);
    
    append(*builder, "@ ");
    append_path(*builder, iterator);
    append(*builder, ": ");
    
    print(*builder, format, ..args);
    log(builder_to_string(*builder));
} @PrintLike

report_error :: (using parser: *JSON_Parser, format: string, args: ..Any) {
    builder: String_Builder;
    
    format_location(*builder, lexer.location);
    print(*builder, format, ..args);
    log(builder_to_string(*builder));
} @PrintLike


// Field parsing is wrapped in a macro so that we can do some funky magic.
// Mostly for the sake of error handling and doing multi-pass stuff
// The parse_object and parse_array for expansions maybe in the future get some special logic that will change how parse_field operates on a second validation pass
parse_field :: (iterator: *JSON_Iterator, identifier: string, value: Any) -> bool #expand {
    if iterator.identifier != identifier   return false;
    
    if !set_value_from_string(value, iterator.value) {
        report_error(iterator, "Failed to parse value of type % from string: '%'.", (*value.type).(*Type).*, iterator.value);
        return false;
    }
    
    iterator.flags |= .HANDLED;
    return true;
}

// This procedure is not intended to be called in the traditional way. 
// You will notice that it does not in fact actually do any parsing in itself! 
// Refer to example.jai for proper use.
parse_object :: inline (iterator: *JSON_Iterator, identifier: string = "") -> *JSON_Iterator {
    if iterator.identifier != identifier   return null;
    if iterator.type != .OBJECT {
        report_error(iterator, "Expected OBJECT, but got %.", iterator.type);
        return null;
    }
    return iterator;
}

// This procedure is not intended to be called in the traditional way. 
// You will notice that it does not in fact actually do any parsing in itself! 
// Refer to example.jai for proper use.
parse_array :: inline (iterator: *JSON_Iterator, identifier: string = "") -> *JSON_Iterator {
    if iterator.identifier != identifier   return null;
    if iterator.type != .ARRAY {
        report_error(iterator, "Expected ARRAY, but got %.", iterator.type);
        return null;
    }
    return iterator;
}

for_expansion :: (using iterator: *JSON_Iterator, $body: Code, for_flags: For_Flags) #expand {
    if iterator == null      return;
    
    if !check_aggr_end(iterator) {
        `it_index := 0;
        while 1 { defer it_index += 1;
            it_ok, it_union := iterator_next(iterator);
            if !it_ok  return;
            `it := (*it_union).(*JSON_Iterator);
            
            #insert body;
            
            if it.flags & .ERROR {
                iterator.flags |= .ERROR;
                return;
            }
            if !(it.flags & .HANDLED)  iterator_skip(it);
            
            expect_another := expect_token_type(*parser.lexer, .COMMA);
            if check_aggr_end(iterator) {
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
    
    iterator.flags |= .HANDLED;
}

check_aggr_end :: (using iterator: *JSON_Iterator) -> bool {
    if iterator.type == {
      case .OBJECT; return check_object_end(parser, (iterator.flags & .IS_ROOT).(bool));
      case .ARRAY;  return check_array\_end(parser);
    }
    assert(false, "Invalid iterator type: %", type);
    return false;
}

check_object_end :: inline (using parser: *JSON_Parser, is_root := false) -> bool {
    return expect_token_type(*lexer, ifx is_root then .EOF else .OBJECT_END);
}

check_array_end :: inline (using parser: *JSON_Parser) -> bool {
    return expect_token_type(*lexer, .ARRAY_END);
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
    
    In order to prevent duplicated checks for fields which have already been parsed, 
    we would like that the parse_xxx procs each contain some internal state variables
    but we cannot do this because there is no 'static' specifier in Jai...
        We could potentially do something really zany where we introspect the body code in the for expansion
        and then create some variable for tracking the state of each call to parse_field 
    
    
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
            ok, str := convert_escape_sequences(text);
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

convert_escape_sequences :: (text: string) -> bool, string {
    builder: String_Builder;
    ok := convert_escape_sequences(*builder, text);
    if !ok {
        free_buffers(*builder);
        return false, "";
    }
    return true, builder_to_string(*builder);
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

