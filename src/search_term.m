% Bower - a frontend for the Notmuch email system
% Copyright (C) 2011 Peter Wang

:- module search_term.
:- interface.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module maybe.

:- import_module prog_config.

%-----------------------------------------------------------------------------%

:- type token.

:- pred predigest_search_string(prog_config::in, string::in,
    maybe_error(list(token))::out, io::di, io::uo) is det.

:- pred tokens_to_search_terms(list(token)::in, string::out, bool::out,
    io::di, io::uo) is det.

:- pred get_default_search_terms(prog_config::in, string::out, io::di, io::uo)
    is det.

:- func search_alias_section = string.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module char.
:- import_module int.
:- import_module parsing_utils.
:- import_module require.
:- import_module set.
:- import_module string.

:- import_module callout.

:- type token
    --->    literal(string)             % pass through to notmuch
    ;       macro(string)               % includes ~ prefix
    ;       date_range(string, string)  % ~d FROM..TO
    ;       do_not_apply_limit.         % ~A

:- inst macro
    --->    macro(ground).

:- type expand_alias_result
    --->    found(list(token))
    ;       not_found
    ;       error(string).

%-----------------------------------------------------------------------------%

predigest_search_string(Config, Input, Res, !IO) :-
    promise_equivalent_solutions [ParseResult] (
        parsing_utils.parse(Input, tokens, ParseResult)
    ),
    (
        ParseResult = ok(Tokens0),
        Seen = set.init,
        expand_config_aliases(Config, Seen, Tokens0, Res, !IO)
    ;
        ParseResult = error(_MaybeError, _Line, _Column),
        Res = error("Error parsing search string.")
    ).

%-----------------------------------------------------------------------------%

:- pred tokens(src::in, list(token)::out, ps::in, ps::out) is semidet.

tokens(Src, Words, !PS) :-
    whitespace(Src, _, !PS),
    zero_or_more(token, Src, Words, !PS),
    eof(Src, _, !PS).

:- pred token(src::in, token::out, ps::in, ps::out) is semidet.

token(Src, Token, !PS) :-
    ( char_in_class("()", Src, Char, !PS) ->
        Word = string.from_char(Char),
        Token = literal(Word)
    ;
        next_char(Src, '~', !PS),
        next_char(Src, 'd', !PS),
        % Disambiguate ~dDATE from alias beginning with ~d.
        date_range_prefix(Src, !PS)
    ->
        date_range(Src, Token, !PS)
    ;
        macro_or_literal(Src, Token, !PS)
    ),
    whitespace(Src, _, !PS).

:- pred date_range_prefix(src::in, ps::in, ps::out) is semidet.

date_range_prefix(Src, !PS) :-
    next_char(Src, Char, !.PS, _),
    ( char.is_whitespace(Char) ->
        whitespace(Src, _, !PS)
    ;
        Char = ('{')
    ).

:- pred date_range(src::in, token::out, ps::in, ps::out) is semidet.

date_range(Src, date_range(FromString, ToString), !PS) :-
    date_string(Src, FromString, !PS),
    (
        next_char(Src, '.', !PS),
        next_char(Src, '.', !PS)
    ->
        date_string(Src, ToString, !PS)
    ;
        ToString = FromString
    ).

:- pred date_string(src::in, string::out, ps::in, ps::out) is semidet.

date_string(Src, DateString, !PS) :-
    ( next_char(Src, '{', !PS) ->
        zero_or_more(bracketed_date_char, Src, Chars, !PS),
        next_char(Src, '}', !PS),
        DateString = string.strip(from_char_list(Chars))
    ;
        zero_or_more(non_bracketed_date_char, Src, Chars, !PS),
        DateString = string.from_char_list(Chars)
    ).

:- pred bracketed_date_char(src::in, char::out, ps::in, ps::out) is semidet.

bracketed_date_char(Src, C, !PS) :-
    next_char(Src, C, !PS),
    C \= ('}').

:- pred non_bracketed_date_char(src::in, char::out, ps::in, ps::out)
    is semidet.

non_bracketed_date_char(Src, C, !PS) :-
    next_char(Src, C, !PS),
    ( C = ('.') ->
        not next_char(Src, '.', !.PS, _PS)
    ;
        not char.is_whitespace(C)
    ).

:- pred macro_or_literal(src::in, token::out, ps::in, ps::out) is semidet.

macro_or_literal(Src, Token, !PS) :-
    current_offset(Src, Start, !PS),
    word_chars(Src, !PS),
    current_offset(Src, End, !PS),
    End > Start,
    input_substring(Src, Start, End, Word),
    ( string.prefix(Word, "~") ->
        ( simple_alias(Word, AliasToken) ->
            Token = AliasToken
        ;
            Token = macro(Word)
        )
    ;
        Token = literal(Word)
    ).

:- pred word_chars(src::in, ps::in, ps::out) is semidet.

word_chars(Src, PS0, PS) :-
    ( next_char(Src, Char, PS0, PS1) ->
        ( is_word_char(Char) ->
            word_chars(Src, PS1, PS)
        ;
            PS = PS0
        )
    ;
        eof(Src, _, PS0, PS)
    ).

:- pred is_word_char(char::in) is semidet.

is_word_char(C) :-
    C \= '(',
    C \= ')',
    not char.is_whitespace(C).

:- pred simple_alias(string::in, token::out) is semidet.

simple_alias("~D", literal("tag:deleted")).
simple_alias("~F", literal("tag:flagged")).
simple_alias("~U", literal("tag:unread")).
simple_alias("~A", do_not_apply_limit).

%-----------------------------------------------------------------------------%

:- pred expand_config_aliases(prog_config::in, set(string)::in,
    list(token)::in, maybe_error(list(token))::out, io::di, io::uo) is det.

expand_config_aliases(Config, Seen, Tokens0, Res, !IO) :-
    (
        Tokens0 = [],
        Res = ok([])
    ;
        Tokens0 = [H0 | T0],
        expand_config_alias(Config, Seen, H0, ResH, !IO),
        (
            ResH = ok(H),
            expand_config_aliases(Config, Seen, T0, ResT, !IO),
            (
                ResT = ok(T),
                Res = ok(H ++ T)
            ;
                ResT = error(Error),
                Res = error(Error)
            )
        ;
            ResH = error(Error),
            Res = error(Error)
        )
    ).

:- pred expand_config_alias(prog_config::in, set(string)::in,
    token::in, maybe_error(list(token))::out, io::di, io::uo) is det.

expand_config_alias(Config, Seen, Token0, Res, !IO) :-
    (
        Token0 = macro(Word0),
        expand_config_alias_macro(Config, Seen, Token0, Res1, !IO),
        (
            Res1 = found(Tokens),
            Res = ok(Tokens)
        ;
            Res1 = not_found,
            Res = ok([literal(Word0)])
        ;
            Res1 = error(Error),
            Res = error(Error)
        )
    ;
        ( Token0 = literal(_)
        ; Token0 = date_range(_, _)
        ; Token0 = do_not_apply_limit
        ),
        Res = ok([Token0])
    ).

:- pred expand_config_alias_macro(prog_config::in, set(string)::in,
    token::in(macro), expand_alias_result::out, io::di, io::uo) is det.

expand_config_alias_macro(Config, Seen0, macro(MacroName), Res, !IO) :-
    (
        string.remove_prefix("~", MacroName, Key),
        not set.contains(Seen0, Key)
    ->
        get_notmuch_config(Config, search_alias_section, Key, ConfigRes, !IO),
        (
            ConfigRes = ok(Expansion),
            set.insert(Key, Seen0, Seen),
            promise_equivalent_solutions [ParseResult] (
                parsing_utils.parse(Expansion, tokens, ParseResult)
            ),
            (
                ParseResult = ok(Tokens0),
                expand_config_aliases(Config, Seen, Tokens0, Res1, !IO),
                (
                    Res1 = ok(Tokens1),
                    Tokens = [literal("(")] ++ Tokens1 ++ [literal(")")],
                    Res = found(Tokens)
                ;
                    Res1 = error(Error),
                    Res = error(Error)
                )
            ;
                ParseResult = error(_, _, _),
                Res = error("Error parsing expansion of " ++ MacroName ++ ".")
            )
        ;
            ConfigRes = error(_Error),
            % XXX Distinguish different types of errors.
            Res = error("Could not expand " ++ MacroName ++ ".")
        )
    ;
        Res = error("Search alias " ++ MacroName ++ " is recursive.")
    ).

%-----------------------------------------------------------------------------%

tokens_to_search_terms(Tokens0, Terms, ApplyLimit, !IO) :-
    ( list.contains(Tokens0, do_not_apply_limit) ->
        ApplyLimit = no
    ;
        ApplyLimit = yes
    ),
    list.map_foldl(token_to_search_term, Tokens0, TermList, !IO),
    Terms = string.join_list(" ", TermList).

:- pred token_to_search_term(token::in, string::out, io::di, io::uo) is det.

token_to_search_term(Token, Term, !IO) :-
    (
        Token = literal(Term)
    ;
        Token = date_range(FromString0, ToString0),
        string.replace_all(FromString0, " ", "_", FromString),
        string.replace_all(ToString0, " ", "_", ToString),
        Term = "date:" ++ FromString ++ ".." ++ ToString
    ;
        Token = do_not_apply_limit,
        Term = ""
    ;
        Token = macro(_),
        % At this stage all macros have been expanded out.
        unexpected($module, $pred, "macro should have been expanded")
    ).

%-----------------------------------------------------------------------------%

get_default_search_terms(Config, Terms, !IO) :-
    get_notmuch_config(Config, search_alias_section, "default", Res, !IO),
    (
        Res = ok(Value),
        Value \= ""
    ->
        Terms = Value
    ;
        Terms = "~d {last week}.."
    ).

%-----------------------------------------------------------------------------%

search_alias_section = "bower:search_alias".

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
