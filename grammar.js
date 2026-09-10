/// <reference types="tree-sitter-cli/dsl" />

// Applied Meta Language (AppliedML) uses the .aml extension. This grammar
// accepts documented spellings plus compiler compatibility aliases;
// dialect-specific completion, diagnostics, and canonicalisation remain the LSP's job.
module.exports = grammar({
  name: "aml",

  extras: $ => [/[\s\uFEFF\u2060\u200B]/, $.comment],
  word: $ => $.identifier,
  conflicts: $ => [[$.expression, $._atomic_type]],

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
      $.form_declaration,
      $.main_declaration,
      $.input_declaration,
      $.permit_declaration,
      $.legacy_term_declaration,
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
      "fn",
      field("name", $.identifier),
      field("parameters", $.parameters),
      optional(seq(":", field("return_type", $.type))),
      choice(field("body", $.block), ";"),
    ),

    form_declaration: $ => seq(
      "form", field("name", $.identifier),
      field("captures", $.form_captures),
      "(", field("parameter", $.form_parameter), ")",
      field("return", $.form_return),
      "marks", field("marks", $.form_marks),
      optional(field("limits", $.form_limits)),
      "=", field("body", $.expression),
    ),
    main_declaration: $ => seq(
      "public", field("name", alias("main", $.identifier)),
      "(", commaSep($.form_parameter), ")",
      field("return", $.form_return),
      "marks", field("marks", $.form_marks),
      optional(field("limits", $.form_limits)),
      "=", field("body", $.expression),
    ),
    form_captures: $ => seq("[", commaSep($.form_parameter), "]"),
    form_parameter: $ => seq(field("multiplicity", choice("many", "once")), field("name", $.identifier), ":", field("type", $.type)),
    form_return: $ => seq("->", "[", field("multiplicity", choice("many", "once")), "]", field("type", $.type)),
    form_marks: $ => seq("{", commaSep($.form_mark), "}"),
    form_mark: $ => seq(field("effect", choice("emit", "write", "read", "fail")), "[", $.number, "]", ":", field("target", $.identifier)),
    form_limits: $ => seq("under", "{", $.form_limit_axis, ",", $.form_limit_axis, ",", $.form_limit_axis, "}"),
    form_limit_axis: $ => seq(field("axis", choice("steps", "depth", "work")), "[", $.number, "]"),

    input_declaration: $ => seq("input", field("binding", $.form_parameter)),
    permit_declaration: $ => seq("permit", field("type", $.capability_type), "=", field("operation", $.identifier)),

    // Calculation-oriented AMLC terms remain parseable beside callable Program
    // syntax. Compiler routing is selected by amlc-lsp, not by this grammar.
    legacy_term_declaration: $ => seq("term", $.expression),
    legacy_parameters: $ => seq("(", commaSep($.legacy_parameter), ")"),
    legacy_parameter: $ => seq(optional(choice("many", "once")), field("name", $.identifier), ":", field("type", $.type)),

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
      $.let_expression,
      $.if_expression,
      $.split_expression,
      $.orbit_expression,
      $.equal_expression,
      $.use_expression,
      $.action_expression,
      $.fold_expression,
      $.generic_call_expression,
      $.tuple_expression,
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

    let_expression: $ => prec.right(seq("let", $.form_parameter, "=", $.expression, "in", $.expression)),
    if_expression: $ => prec.right(seq("if", $.expression, "then", $.expression, "else", $.expression)),
    split_expression: $ => prec.right(seq("split", $.expression, "as", $.form_parameter, ",", $.form_parameter, "in", $.expression)),
    orbit_expression: $ => prec.right(seq("orbit", "[", $.number, optional(seq(",", $.expression)), "]", "from", $.expression, "with", $.form_parameter, "=>", $.expression)),
    equal_expression: $ => seq("equal", "[", $.type, "]", "(", $.expression, ",", $.expression, ")"),
    use_expression: $ => prec.right(seq("use", field("function", $.identifier), "[", commaSep($.expression), "]", "(", $.expression, ")", "as", $.form_parameter, "in", $.expression)),
    action_expression: $ => seq(field("effect", choice("emit", "write", "read", "fail")), "[", $.number, "]", "(", $.expression, ")"),
    fold_expression: $ => prec.right(seq("fold", $.expression, "from", $.expression, "with", $.form_parameter, ",", $.form_parameter, "=>", $.expression)),
    generic_call_expression: $ => prec.left(10, seq(field("function", $.identifier), "[", field("type", $.type), "]", field("arguments", $.arguments))),
    tuple_expression: $ => seq("(", $.expression, repeat1(seq(",", $.expression)), optional(","), ")"),

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

    type: $ => choice($.product_type, $._atomic_type),
    _atomic_type: $ => choice($.primitive_type, $.sized_type, $.map_type, $.list_type, $.sequence_type, $.capability_type, $.option_type, $.tuple_type, $.identifier),
    product_type: $ => prec.right(1, seq($._atomic_type, repeat1(seq("*", $._atomic_type)))),
    primitive_type: $ => choice("int", "bool", "string", "address", "bytes", "bytes32", "u64", "u128", "u256", "uint", "sint", "cipher", "pubkey", "unit", "void"),
    sized_type: $ => prec(1, seq(choice("uint", "sint", "bytes"), "[", $.number, "]")),
    map_type: $ => seq("map", "[", $.type, "]", $.type),
    list_type: $ => seq(choice("list", "vec"), "[", $.type, "]"),
    sequence_type: $ => seq(choice("seq", "vec"), "[", $.number, ",", $.type, "]"),
    capability_type: $ => seq("cap", "[", $.number, "]"),
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
