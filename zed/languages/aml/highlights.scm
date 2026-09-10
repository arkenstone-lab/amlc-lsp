[
  "contract"
  "Contract"
  "program"
  "Program"
  "interface"
  "import"
  "from"
  "as"
  "implements"
  "struct"
  "enum"
  "state"
  "event"
  "const"
  "invariant"
  "constructor"
  "fn"
  "form"
  "input"
  "permit"
  "once"
  "many"
  "marks"
  "under"
  "steps"
  "depth"
  "work"
  "use"
  "split"
  "orbit"
  "equal"
  "then"
  "with"
  "write"
  "read"
  "fail"
  "fold"
  "public"
  "private"
  "internal"
  "view"
  "pure"
  "payable"
  "nonreentrant"
  "export"
  "let"
  "var"
  "return"
  "require"
  "emit"
  "revert"
  "if"
  "else"
  "while"
  "for"
  "in"
] @keyword

[(primitive_type) (sized_type) (sequence_type) (capability_type) (map_type) (list_type) (option_type) (tuple_type) (product_type)] @type
(contract_declaration name: (identifier) @type)
(program_declaration name: (identifier) @type)
(interface_declaration name: (identifier) @type)
(struct_declaration name: (identifier) @type)
(enum_declaration name: (identifier) @type)

(function_declaration name: (identifier) @function)
(form_declaration name: (identifier) @function)
(main_declaration name: (identifier) @function)
(event_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
(member_expression property: (identifier) @function.method)

(parameter name: (identifier) @variable.parameter)
(form_parameter name: (identifier) @variable.parameter)
(input_declaration binding: (form_parameter name: (identifier) @variable.parameter))
(field_declaration name: (identifier) @property)
(constant_declaration name: (identifier) @constant)
(self) @variable.special
(comment) @comment
(string) @string
(number) @number
(boolean) @boolean
((identifier) @constant
  (#any-of? @constant "Some" "some" "None" "none"))

[
  "="
  "+="
  "-="
  "*="
  "/="
  "+"
  "-"
  "*"
  "/"
  "%"
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "&&"
  "||"
  "and"
  "or"
  "not"
  "!"
] @operator
