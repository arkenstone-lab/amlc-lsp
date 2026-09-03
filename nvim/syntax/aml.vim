" AppliedML / AML contract DSL fallback highlighting.
if exists("b:current_syntax")
  finish
endif

syn keyword amlKeyword contract Contract program Program state event constructor fn view pure private public internal payable
syn keyword amlKeyword invariant implements import const let return assert require emit if else while for in match struct enum interface
syn keyword amlBuiltin self caller origin self_addr epoch epoch_time value balance tree_hash node_id tx_hash unwrap is_some assert_address len
syn keyword amlBoolean true false None none Some some
syn keyword amlType int bool string address bytes bytes32 u64 u128 u256 uint cipher pubkey map list Option option
syn match amlComment "//.*$"
syn region amlComment start="/\*" end="\*/" contains=amlComment
syn region amlString start=+"+ skip=+\\"+ end=+"+
syn match amlNumber "\<\d\(\d\|_\)*\>"
syn match amlField "\<self\.\zs[A-Za-z_][A-Za-z0-9_]*"

hi def link amlKeyword Keyword
hi def link amlBuiltin Special
hi def link amlBoolean Boolean
hi def link amlType Type
hi def link amlComment Comment
hi def link amlString String
hi def link amlNumber Number
hi def link amlField Identifier

let b:current_syntax = "aml"
