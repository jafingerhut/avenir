{
  open Parser

  exception ParseError of string


}

let id = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*


rule tokens = parse
| [' ' '\t' '\n'] { tokens lexbuf }
| ['0'-'9']+ as i { INT (int_of_string i) }
| "true"          { TRUE }
| "false"         { FALSE }
| "while"         { WHILE }
| "skip"          { SKIP }
| ":="            { ASSIGN }
| "->"            { CASE }
| "if"            { IF }
| "fi"            { FI }
| "||"            { OR }
| "&&"            { AND }
| "~"             { NOT }
| "="             { EQ }
| "("             { LPAREN }
| ")"             { RPAREN }
| "{"             { LBRACE }
| "}"             { RBRACE }
| ";"             { SEMICOLON }
| eof             { EOF }
| id as x         { ID x }
| _ { raise (ParseError (Printf.sprintf "At offset %d: unexpected character.\n" (Lexing.lexeme_start lexbuf))) }