defmodule Code.Fragment do
  @moduledoc """
  This module provides conveniences for analyzing fragments of
  textual code and extract available information whenever possible.

  Most of the function in this module provides a best-effort
  and may not be accurate under all circumstances. Read each
  documentation for more information.

  This module should be considered experimental.
  """

  @doc """
  Receives a string and returns the cursor context.

  This function receives a string with an Elixir code fragment,
  representing a cursor position, and based on the string, it
  provides contextual information about said position. The
  return of this function can then be used to provide tips,
  suggestions, and autocompletion functionality.

  This function provides a best-effort detection and may not be
  accurate under all circumstances. See the "Limitations"
  section below.

  Consider adding a catch-all clause when handling the return
  type of this function as new cursor information may be added
  in future releases.

  ## Examples

      iex> Code.cursor_context("")
      :expr

      iex> Code.cursor_context("hello_wor")
      {:local_or_var, 'hello_wor'}

  ## Return values

    * `{:alias, charlist}` - the context is an alias, potentially
      a nested one, such as `Hello.Wor` or `HelloWor`

    * `{:dot, inside_dot, charlist}` - the context is a dot
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, this may either be a remote call or a map
      field access. Examples are `Hello.wor`, `:hello.wor`, `hello.wor`,
      `Hello.nested.wor`, `hello.nested.wor`, and `@hello.world`

    * `{:dot_arity, inside_dot, charlist}` - the context is a dot arity
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, it must be a remote arity. Examples are
      `Hello.world/`, `:hello.world/`, `hello.world/2`, and `@hello.world/2`

    * `{:dot_call, inside_dot, charlist}` - the context is a dot
      call. This means parentheses or space have been added after the expression.
      where `inside_dot` is either a `{:var, charlist}`, `{:alias, charlist}`,
      `{:module_attribute, charlist}`, `{:unquoted_atom, charlist}` or a `dot`
      itself. If a var is given, it must be a remote call. Examples are
      `Hello.world(`, `:hello.world(`, `Hello.world `, `hello.world(`, `hello.world `,
      and `@hello.world(`

    * `:expr` - may be any expression. Autocompletion may suggest an alias,
      local or var

    * `{:local_or_var, charlist}` - the context is a variable or a local
      (import or local) call, such as `hello_wor`

    * `{:local_arity, charlist}` - the context is a local (import or local)
      arity, such as `hello_world/`

    * `{:local_call, charlist}` - the context is a local (import or local)
      call, such as `hello_world(` and `hello_world `

    * `{:module_attribute, charlist}` - the context is a module attribute, such
      as `@hello_wor`

    * `{:operator, charlist}` (since v1.13.0) - the context is an operator,
      such as `+` or `==`. Note textual operators, such as `when` do not
      appear as operators but rather as `:local_or_var`. `@` is never an
      `:operator` and always a `:module_attribute`

    * `{:operator_arity, charlist}` (since v1.13.0)  - the context is an
      operator arity, which is an operator followed by /, such as `+/`,
      `not/` or `when/`

    * `{:operator_call, charlist}` (since v1.13.0)  - the context is an
      operator call, which is an operator followed by space, such as
      `left + `, `not ` or `x when `

    * `:none` - no context possible

    * `:unquoted_atom` - the context is an unquoted atom. This can be any atom
      or an atom representing a module

  ## Limitations

    * The current algorithm only considers the last line of the input
    * Context does not yet track strings and sigils
    * Arguments of functions calls are not currently recognized

  """
  @doc since: "1.13.0"
  @spec cursor_context(List.Chars.t(), keyword()) ::
          {:alias, charlist}
          | {:dot, inside_dot, charlist}
          | {:dot_arity, inside_dot, charlist}
          | {:dot_call, inside_dot, charlist}
          | :expr
          | {:local_or_var, charlist}
          | {:local_arity, charlist}
          | {:local_call, charlist}
          | {:module_attribute, charlist}
          | {:operator, charlist}
          | {:operator_arity, charlist}
          | {:operator_call, charlist}
          | :none
          | {:unquoted_atom, charlist}
        when inside_dot:
               {:alias, charlist}
               | {:dot, inside_dot, charlist}
               | {:module_attribute, charlist}
               | {:unquoted_atom, charlist}
               | {:var, charlist}
  def cursor_context(string, opts \\ [])

  def cursor_context(binary, opts) when is_binary(binary) and is_list(opts) do
    binary =
      case :binary.matches(binary, "\n") do
        [] ->
          binary

        matches ->
          {position, _} = List.last(matches)
          binary_part(binary, position + 1, byte_size(binary) - position - 1)
      end

    do_cursor_context(String.to_charlist(binary), opts)
  end

  def cursor_context(charlist, opts) when is_list(charlist) and is_list(opts) do
    chunked = Enum.chunk_by(charlist, &(&1 == ?\n))

    case List.last(chunked, []) do
      [?\n | _] -> do_cursor_context([], opts)
      rest -> do_cursor_context(rest, opts)
    end
  end

  def cursor_context(other, opts) do
    cursor_context(to_charlist(other), opts)
  end

  @operators '\\<>+-*/:=|&~^%.!'
  @starter_punctuation ',([{;'
  @non_starter_punctuation ')]}"\''
  @space '\t\s'
  @trailing_identifier '?!'

  @non_identifier @trailing_identifier ++
                    @operators ++ @starter_punctuation ++ @non_starter_punctuation ++ @space

  @incomplete_operators ['^^', '~~', '~']
  @textual_operators ['when', 'not', 'and', 'or']

  defp do_cursor_context(list, _opts) do
    reverse = Enum.reverse(list)

    case strip_spaces(reverse, 0) do
      # It is empty
      {[], _} -> :expr
      # Token/AST only operators
      {[?>, ?= | rest], _} when rest == [] or hd(rest) != ?: -> :expr
      {[?>, ?- | rest], _} when rest == [] or hd(rest) != ?: -> :expr
      # Two-digit containers
      {[?<, ?< | rest], _} when rest == [] or hd(rest) != ?< -> :expr
      # Ambiguity around :
      {[?: | _], 0} -> {:unquoted_atom, ''}
      {[?:, next | _], _} when next != ?: -> :expr
      # Dots
      {[?.], _} -> :none
      {[?. | rest], _} when hd(rest) not in '.:' -> dot(rest, '')
      # It is a local or remote call with parens
      {[?( | rest], _} -> call_to_cursor_context(rest)
      # A local arity definition
      {[?/ | rest], _} -> arity_to_cursor_context(rest)
      # Starting a new expression
      {[h | _], _} when h in @starter_punctuation -> :expr
      # It is a local or remote call without parens
      {rest, spaces} when spaces > 0 -> call_to_cursor_context(rest)
      # It is an identifier
      _ -> identifier_to_cursor_context(reverse, false)
    end
  end

  defp strip_spaces([h | rest], count) when h in @space, do: strip_spaces(rest, count + 1)
  defp strip_spaces(rest, count), do: {rest, count}

  defp arity_to_cursor_context(reverse) do
    case identifier_to_cursor_context(reverse, true) do
      {:local_or_var, acc} -> {:local_arity, acc}
      {:operator, acc} -> {:operator_arity, acc}
      {:dot, base, acc} -> {:dot_arity, base, acc}
      _ -> :none
    end
  end

  defp call_to_cursor_context(reverse) do
    case identifier_to_cursor_context(reverse, true) do
      {:local_or_var, acc} -> {:local_call, acc}
      {:dot, base, acc} -> {:dot_call, base, acc}
      {:operator, acc} -> {:operator_call, acc}
      _ -> :none
    end
  end

  defp identifier_to_cursor_context(reverse, call_op?) do
    case identifier(reverse) do
      # Operators and module attributes
      :maybe_operator -> operator(reverse, [], call_op?)
      {:module_attribute, acc} -> {:module_attribute, acc}
      # Ignore identifiers leading to a question mark
      {_, _, '?' ++ _, _} -> :none
      # Parse :: first to avoid ambiguity with atoms
      {:alias, false, '::' ++ _, _} -> :none
      {kind, _, '::' ++ _, acc} -> alias_or_local_or_var(kind, acc)
      # Now handle atoms, any other atom is unexpected, and then ignore non-ascii aliases
      {_kind, _, ':' ++ _, acc} -> {:unquoted_atom, acc}
      {:atom, _, _, _} -> :none
      {:alias, false, _, _} -> :none
      # Parse .. first to avoid ambiguity with dots
      {kind, _, '..' ++ _, acc} -> alias_or_local_or_var(kind, acc)
      # Everything else
      {:alias, _, '.' ++ rest, acc} -> nested_alias(rest, acc)
      {:identifier, _, '.' ++ rest, acc} -> dot(rest, acc)
      {:alias, _, _, acc} -> {:alias, acc}
      {:identifier, _, _, acc} when call_op? and acc in @textual_operators -> {:operator, acc}
      {:identifier, _, _, acc} -> {:local_or_var, acc}
      :none -> :none
    end
  end

  defp nested_alias(rest, acc) do
    case identifier_to_cursor_context(rest, true) do
      {:alias, prev} -> {:alias, prev ++ '.' ++ acc}
      _ -> :none
    end
  end

  defp dot(rest, acc) do
    case identifier_to_cursor_context(rest, true) do
      {:local_or_var, prev} -> {:dot, {:var, prev}, acc}
      {:unquoted_atom, _} = prev -> {:dot, prev, acc}
      {:alias, _} = prev -> {:dot, prev, acc}
      {:dot, _, _} = prev -> {:dot, prev, acc}
      {:module_attribute, _} = prev -> {:dot, prev, acc}
      _ -> :none
    end
  end

  defp alias_or_local_or_var(:alias, acc), do: {:alias, acc}
  defp alias_or_local_or_var(:identifier, acc), do: {:local_or_var, acc}
  defp alias_or_local_or_var(_, _), do: :none

  defp identifier([?? | rest]), do: check_identifier(rest, [??])
  defp identifier([?! | rest]), do: check_identifier(rest, [?!])
  defp identifier(rest), do: check_identifier(rest, [])

  defp check_identifier([h | _], _acc) when h in @operators, do: :maybe_operator
  defp check_identifier([h | _], _acc) when h in @non_identifier, do: :none
  defp check_identifier([], _acc), do: :maybe_operator
  defp check_identifier(rest, acc), do: rest_identifier(rest, acc)

  defp rest_identifier([h | rest], acc) when h not in @non_identifier do
    rest_identifier(rest, [h | acc])
  end

  defp rest_identifier(rest, [?@ | acc]) do
    case tokenize_identifier(rest, acc) do
      {:identifier, _ascii_only?, _rest, acc} -> {:module_attribute, acc}
      :none when acc == [] -> {:module_attribute, ''}
      _ -> :none
    end
  end

  defp rest_identifier(rest, acc) do
    tokenize_identifier(rest, acc)
  end

  defp tokenize_identifier(rest, acc) do
    case String.Tokenizer.tokenize(acc) do
      {kind, _, [], _, ascii_only?, extra} ->
        if ?@ in extra and not match?([?: | _], rest) do
          :none
        else
          {kind, ascii_only?, rest, acc}
        end

      _ ->
        :none
    end
  end

  defp operator([h | rest], acc, call_op?) when h in @operators do
    operator(rest, [h | acc], call_op?)
  end

  defp operator(_rest, acc, call_op?) when acc in @incomplete_operators do
    if call_op?, do: :none, else: {:operator, acc}
  end

  defp operator(rest, [?. | acc], call_op?) when acc in @incomplete_operators do
    if call_op?, do: :none, else: dot(rest, acc)
  end

  defp operator(rest, acc, _call_op?) do
    case :elixir_tokenizer.tokenize(acc, 1, 1, []) do
      {:ok, _, [{:atom, _, acc}]} ->
        {:unquoted_atom, Atom.to_charlist(acc)}

      {:ok, _, [{:., _}, {_, _, op}]} ->
        if Code.Identifier.unary_op(op) != :error or Code.Identifier.binary_op(op) != :error do
          dot(rest, Atom.to_charlist(op))
        else
          :none
        end

      {:ok, _, [{_, _, op}]} ->
        if Code.Identifier.unary_op(op) != :error or Code.Identifier.binary_op(op) != :error do
          {:operator, Atom.to_charlist(op)}
        else
          :none
        end

      _ ->
        :none
    end
  end
end