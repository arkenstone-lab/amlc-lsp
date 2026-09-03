/// <reference types="tree-sitter-cli/dsl" />

// AML and AppliedML share the .aml extension.  This grammar deliberately
// covers their common editor surface (declarations, types, expressions and
// blocks) rather than duplicating either compiler's semantic validation.
module.exports = grammar({
  name: "aml",

  extras: $ => [/[\s\uFEFF\u2060\u200B]/, $.comment],
  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat($._item),

    _item: $ => choice(
      $.import_declaration,
      $.contract_declaration,
      $.interface_declaration,
      $.program_declaration,
      $.struct_declaration,
      $.enum_declaration,
      $.state_declaration,
      $.event_declaration,
      $.function_declaration,
      $.constructor_declaration,
      $.constant_declaration,
      $.invariant_declaration,
      $.field_declaration,
      $.statement,
    ),

    contract_declaration: $ => seq(
      field("keyword", choice("contract", "Contract")),
      field("name", $.identifier),
      optional($.implements_clause),
      field("body", $.block),
    ),

    program_declaration: $ => seq(
      field("keyword", choice("program", "Program")),
      field("name", $.identifier),
      optional($.implements_clause),
      field("body", $.block),
    ),

    interface_declaration: $ => seq(
      "interface",
      field("name", $.identifier),
      field("body", $.block),
    ),

    implements_clause: $ => seq("implements", commaSep1($.identifier)),

    import_declaration: $ => choice(
      seq("import", commaSep1($.identifier), "from", field("path", $.string)),
      seq("import", field("path", $.string), "as", field("alias", $.identifier)),
    ),

    struct_declaration: $ => seq("struct", field("name", $.identifier), field("body", $.block)),
    enum_declaration: $ => seq("enum", field("name", $.identifier), field("body", $.block)),
    state_declaration: $ => seq("state", field("body", $.block)),
    event_declaration: $ => seq("event", field("name", $.identifier), $.parameters),

    constant_declaration: $ => seq("const", field("name", $.identifier), ":", field("type", $.type), "=", field("value", $.expression)),
    invariant_declaration: $ => seq("invariant", field("name", $.identifier), "=", field("condition", $.expression)),
    field_declaration: $ => seq(field("name", $.identifier), ":", field("type", $.type)),

    function_declaration: $ => seq(
      repeat(choice("public", "private", "internal", "view", "pure", "payable", "nonreentrant", "export")),
      choice("fn", "form"),
      field("name", $.identifier),
      field("parameters", $.parameters),
      optional(seq(":", field("return_type", $.type))),
      choice(field("body", $.block), ";"),
    ),

    constructor_declaration: $ => seq("constructor", field("parameters", $.parameters), field("body", $.block)),
    parameters: $ => seq("(", commaSep($.parameter), ")"),
    parameter: $ => seq(field("name", $.identifier), optional(seq(":", field("type", $.type)))),

    block: $ => seq("{", repeat($._item), "}"),

    statement: $ => choice(
      $.let_statement,
      $.return_statement,
      $.require_statement,
      $.emit_statement,
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.revert_statement,
      $.assignment_statement,
      $.expression_statement,
    ),

    let_statement: $ => seq(choice("let", "var"), field("name", $.identifier), optional(seq(":", field("type", $.type))), optional(seq("=", field("value", $.expression)))),
    return_statement: $ => prec.right(seq("return", optional($.expression))),
    require_statement: $ => seq("require", "(", commaSep1($.expression), ")"),
    emit_statement: $ => seq("emit", $.call_expression),
    revert_statement: $ => prec.right(seq("revert", optional($.expression))),
    if_statement: $ => prec.right(seq("if", field("condition", $.expression), field("consequence", $.block), optional(seq("else", choice($.block, $.if_statement))))),
    while_statement: $ => seq("while", field("condition", $.expression), field("body", $.block)),
    for_statement: $ => seq("for", field("name", $.identifier), "in", field("iterable", $.expression), field("body", $.block)),
    assignment_statement: $ => seq(field("left", $.expression), choice("=", "+=", "-=", "*=", "/="), field("right", $.expression)),
    expression_statement: $ => $.expression,

    expression: $ => choice(
      $.identifier,
      $.self,
      $.literal,
      $.call_expression,
      $.member_expression,
      $.index_expression,
      $.unary_expression,
      $.binary_expression,
      $.parenthesized_expression,
      $.list,
      $.map,
    ),

    call_expression: $ => prec.left(10, seq(field("function", choice($.identifier, $.member_expression)), field("arguments", $.arguments))),
    arguments: $ => seq("(", commaSep($.expression), ")"),
    member_expression: $ => prec.left(9, seq(field("object", choice($.identifier, $.self, $.call_expression, $.index_expression)), ".", field("property", $.identifier))),
    index_expression: $ => prec.left(9, seq(field("object", choice($.identifier, $.self, $.member_expression)), "[", field("index", $.expression), "]")),
    unary_expression: $ => prec(8, seq(choice("!", "-", "not"), $.expression)),
    binary_expression: $ => choice(
      ...[
        ["||", 1], ["or", 1], ["&&", 2], ["and", 2], ["==", 3], ["!=", 3],
        ["<", 4], ["<=", 4], [">", 4], [">=", 4], ["+", 5], ["-", 5],
        ["*", 6], ["/", 6], ["%", 6],
      ].map(([operator, precedence]) => prec.left(precedence, seq($.expression, operator, $.expression))),
    ),
    parenthesized_expression: $ => seq("(", $.expression, ")"),
    self: $ => "self",
    literal: $ => choice($.number, $.string, $.boolean, $.address_literal),
    boolean: $ => choice("true", "false"),
    list: $ => seq("[", commaSep($.expression), "]"),
    map: $ => seq("{", commaSep(seq($.expression, ":", $.expression)), "}"),

    type: $ => choice($.primitive_type, $.map_type, $.list_type, $.option_type, $.tuple_type, $.identifier),
    primitive_type: $ => choice("int", "bool", "string", "address", "bytes", "bytes32", "u64", "u128", "u256", "uint", "cipher", "pubkey", "unit", "void"),
    map_type: $ => seq("map", "[", $.type, "]", $.type),
    list_type: $ => seq(choice("list", "vec"), "[", $.type, "]"),
    option_type: $ => seq(choice("Option", "option"), "[", $.type, "]"),
    tuple_type: $ => seq("(", commaSep1($.type), ")"),

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    number: _ => /(?:0x[0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?)/,
    address_literal: _ => /0x[0-9a-fA-F]{8,}/,
    string: $ => seq('"', repeat(choice(/[^"\\\n]+/, /\\./)), '"'),
    comment: _ => token(choice(seq("//", /[^\n]*/), seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/"))),
  },
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)), optional(","));
}
