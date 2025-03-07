defmodule Explorer.Series do
  @moduledoc """
  The Series struct and API.

  A series can be of the following data types:

    * `:binary` - Binary
    * `:boolean` - Boolean
    * `:category` - UTF-8 encoded binary but represented internally as integers
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`
    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:string` - UTF-8 encoded binary
    * `:time` - Time type that unwraps to `Elixir.Time`

  A series must consist of a single data type only. Series may have `nil` values in them.
  The series `dtype` can be retrieved via the `dtype/1` function or directly accessed as
  `series.dtype`. A `series.name` field is also available, but it is always `nil` unless
  the series is retrieved from a dataframe.

  Many functions only apply to certain dtypes. These functions may appear on distinct
  categories on the sidebar. Other functions may work on several datatypes, such as
  comparison functions. In such cases, a "Supported dtypes" section will be available
  in the function documentation.

  ## Creating series

  Series can be created using `from_list/2`, `from_binary/3`, and friends:

  Series can be made of numbers:

      iex> Explorer.Series.from_list([1, 2, 3])
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >

  Series are nullable, so you may also include nils:

      iex> Explorer.Series.from_list([1.0, nil, 2.5, 3.1])
      #Explorer.Series<
        Polars[4]
        float [1.0, nil, 2.5, 3.1]
      >

  Any of the dtypes above are supported, such as strings:

      iex> Explorer.Series.from_list(["foo", "bar", "baz"])
      #Explorer.Series<
        Polars[3]
        string ["foo", "bar", "baz"]
      >

  """

  import Kernel, except: [and: 2, not: 1, in: 2]

  alias __MODULE__, as: Series
  alias Kernel, as: K
  alias Explorer.Shared

  @valid_dtypes Explorer.Shared.dtypes()

  @type dtype ::
          :binary
          | :boolean
          | :category
          | :date
          | :time
          | :datetime
          | :float
          | :integer
          | :string

  @type t :: %Series{data: Explorer.Backend.Series.t(), dtype: dtype()}
  @type lazy_t :: %Series{data: Explorer.Backend.LazySeries.t(), dtype: dtype()}

  @type non_finite :: :nan | :infinity | :neg_infinity

  @doc false
  @enforce_keys [:data, :dtype]
  defstruct [:data, :dtype, :name]

  @behaviour Access
  @compile {:no_warn_undefined, Nx}

  defguardp is_numerical(n) when K.or(is_number(n), K.in(n, [:nan, :infinity, :neg_infinity]))
  defguardp is_io_dtype(dtype) when K.not(K.in(dtype, [:binary, :string]))
  defguardp is_numeric_dtype(dtype) when K.in(dtype, [:float, :integer])
  defguardp is_numeric_or_bool_dtype(dtype) when K.in(dtype, [:float, :integer, :boolean])

  defguardp is_numeric_or_date_dtype(dtype)
            when K.in(dtype, [:float, :integer, :date, :time, :datetime])

  @impl true
  def fetch(series, idx) when is_integer(idx), do: {:ok, fetch!(series, idx)}
  def fetch(series, indices) when is_list(indices), do: {:ok, slice(series, indices)}
  def fetch(series, %Range{} = range), do: {:ok, slice(series, range)}

  @impl true
  def pop(series, idx) when is_integer(idx) do
    mask = 0..(size(series) - 1) |> Enum.map(&(&1 != idx)) |> from_list()
    value = fetch!(series, idx)
    series = mask(series, mask)
    {value, series}
  end

  def pop(series, indices) when is_list(indices) do
    mask = 0..(size(series) - 1) |> Enum.map(&K.not(Enum.member?(indices, &1))) |> from_list()
    value = slice(series, indices)
    series = mask(series, mask)
    {value, series}
  end

  def pop(series, %Range{} = range) do
    mask = 0..(size(series) - 1) |> Enum.map(&K.not(Enum.member?(range, &1))) |> from_list()
    value = slice(series, range)
    series = mask(series, mask)
    {value, series}
  end

  @impl true
  def get_and_update(series, idx, fun) when is_integer(idx) do
    value = fetch!(series, idx)
    {current_value, new_value} = fun.(value)
    new_data = series |> to_list() |> List.replace_at(idx, new_value) |> from_list()
    {current_value, new_data}
  end

  defp fetch!(series, idx) do
    size = size(series)
    idx = if idx < 0, do: idx + size, else: idx

    if K.or(idx < 0, idx > size),
      do: raise(ArgumentError, "index #{idx} out of bounds for series of size #{size}")

    apply_series(series, :at, [idx])
  end

  # Conversion

  @doc """
  Creates a new series from a list.

  The list must consist of a single data type and nils. It is possible to have
  a list of only nil values. In this case, the list will have the `:dtype` of float.

  ## Options

    * `:backend` - The backend to allocate the series on.
    * `:dtype` - Cast the series to a given `:dtype`. By default this is `nil`, which means
      that Explorer will infer the type from the values in the list.

  ## Examples

  Explorer will infer the type from the values in the list:

      iex> Explorer.Series.from_list([1, 2, 3])
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >

  Series are nullable, so you may also include nils:

      iex> Explorer.Series.from_list([1.0, nil, 2.5, 3.1])
      #Explorer.Series<
        Polars[4]
        float [1.0, nil, 2.5, 3.1]
      >

  A mix of integers and floats will be cast to a float:

      iex> Explorer.Series.from_list([1, 2.0])
      #Explorer.Series<
        Polars[2]
        float [1.0, 2.0]
      >

  Floats series can accept NaN, Inf, and -Inf values:

      iex> Explorer.Series.from_list([1.0, 2.0, :nan, 4.0])
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, NaN, 4.0]
      >

      iex> Explorer.Series.from_list([1.0, 2.0, :infinity, 4.0])
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, Inf, 4.0]
      >

      iex> Explorer.Series.from_list([1.0, 2.0, :neg_infinity, 4.0])
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, -Inf, 4.0]
      >

  Trying to create a "nil" series will, by default, result in a series of floats:

      iex> Explorer.Series.from_list([nil, nil])
      #Explorer.Series<
        Polars[2]
        float [nil, nil]
      >

  You can specify the desired `dtype` for a series with the `:dtype` option.

      iex> Explorer.Series.from_list([nil, nil], dtype: :integer)
      #Explorer.Series<
        Polars[2]
        integer [nil, nil]
      >

      iex> Explorer.Series.from_list([1, nil], dtype: :string)
      #Explorer.Series<
        Polars[2]
        string ["1", nil]
      >

  The `dtype` option is particulary important if a `:binary` series is desired, because
  by default binary series will have the dtype of `:string`:

      iex> Explorer.Series.from_list([<<228, 146, 51>>, <<42, 209, 236>>], dtype: :binary)
      #Explorer.Series<
        Polars[2]
        binary [<<228, 146, 51>>, <<42, 209, 236>>]
      >

  A series mixing UTF8 strings and binaries is possible:

      iex> Explorer.Series.from_list([<<228, 146, 51>>, "Elixir"], dtype: :binary)
      #Explorer.Series<
        Polars[2]
        binary [<<228, 146, 51>>, "Elixir"]
      >

  Another option is to create a categorical series from a list of strings:

      iex> Explorer.Series.from_list(["EUA", "Brazil", "Poland"], dtype: :category)
      #Explorer.Series<
        Polars[3]
        category ["EUA", "Brazil", "Poland"]
      >

  It is possible to create a series of `:datetime` from a list of microseconds since Unix Epoch.

      iex> Explorer.Series.from_list([1649883642 * 1_000 * 1_000], dtype: :datetime)
      #Explorer.Series<
        Polars[1]
        datetime [2022-04-13 21:00:42.000000]
      >

  It is possible to create a series of `:time` from a list of microseconds since midnight.

      iex> Explorer.Series.from_list([123 * 1_000 * 1_000], dtype: :time)
      #Explorer.Series<
        Polars[1]
        time [00:02:03.000000]
      >

  Mixing non-numeric data types will raise an ArgumentError:

      iex> Explorer.Series.from_list([1, "a"])
      ** (ArgumentError) the value "a" does not match the inferred series dtype :integer
  """
  @doc type: :conversion
  @spec from_list(list :: list(), opts :: Keyword.t()) :: Series.t()
  def from_list(list, opts \\ []) do
    opts = Keyword.validate!(opts, [:dtype, :backend])
    backend = backend_from_options!(opts)

    type = Shared.check_types!(list, opts[:dtype])
    {list, type} = Shared.cast_numerics(list, type)

    series = backend.from_list(list, type)

    case check_optional_dtype!(opts[:dtype]) do
      nil -> series
      ^type -> series
      other -> cast(series, other)
    end
  end

  defp check_optional_dtype!(nil), do: nil
  defp check_optional_dtype!(dtype) when K.in(dtype, @valid_dtypes), do: dtype

  defp check_optional_dtype!(dtype) do
    raise ArgumentError, "unsupported datatype: #{inspect(dtype)}"
  end

  @doc """
  Builds a series of `dtype` from `binary`.

  All binaries must be in native endianness.

  ## Options

    * `:backend` - The backend to allocate the series on.

  ## Examples

  Integers and floats follow their native encoding:

      iex> Explorer.Series.from_binary(<<1.0::float-64-native, 2.0::float-64-native>>, :float)
      #Explorer.Series<
        Polars[2]
        float [1.0, 2.0]
      >

      iex> Explorer.Series.from_binary(<<-1::signed-64-native, 1::signed-64-native>>, :integer)
      #Explorer.Series<
        Polars[2]
        integer [-1, 1]
      >

  Booleans are unsigned integers:

      iex> Explorer.Series.from_binary(<<1, 0, 1>>, :boolean)
      #Explorer.Series<
        Polars[3]
        boolean [true, false, true]
      >

  Dates are encoded as i32 representing days from the Unix epoch (1970-01-01):

      iex> binary = <<-719162::signed-32-native, 0::signed-32-native, 6129::signed-32-native>>
      iex> Explorer.Series.from_binary(binary, :date)
      #Explorer.Series<
        Polars[3]
        date [0001-01-01, 1970-01-01, 1986-10-13]
      >

  Times are encoded as i64 representing microseconds from midnight:

      iex> binary = <<0::signed-64-native, 86399999999::signed-64-native>>
      iex> Explorer.Series.from_binary(binary, :time)
      #Explorer.Series<
        Polars[2]
        time [00:00:00.000000, 23:59:59.999999]
      >

  Datetimes are encoded as i64 representing microseconds from the Unix epoch (1970-01-01):

      iex> binary = <<0::signed-64-native, 529550625987654::signed-64-native>>
      iex> Explorer.Series.from_binary(binary, :datetime)
      #Explorer.Series<
        Polars[2]
        datetime [1970-01-01 00:00:00.000000, 1986-10-13 01:23:45.987654]
      >

  """
  @doc type: :conversion
  @spec from_binary(binary, :float | :integer | :boolean | :date | :time | :datetime, keyword) ::
          Series.t()
  def from_binary(binary, dtype, opts \\ [])
      when K.and(is_binary(binary), K.and(is_atom(dtype), is_list(opts))) do
    opts = Keyword.validate!(opts, [:dtype, :backend])
    {_type, alignment} = Shared.dtype_to_iotype!(dtype)

    if rem(bit_size(binary), alignment) != 0 do
      raise ArgumentError, "binary for dtype #{dtype} is expected to be #{alignment}-bit aligned"
    end

    backend = backend_from_options!(opts)
    backend.from_binary(binary, dtype)
  end

  @doc """
  Converts a `t:Nx.Tensor.t/0` to a series.

  > #### Warning {: .warning}
  >
  > `Nx` is an optional dependency. You will need to ensure it's installed to use this function.

  ## Options

    * `:backend` - The backend to allocate the series on.
    * `:dtype` - The dtype of the series, it must match the underlying tensor type.

  ## Examples

  Integers and floats:

      iex> tensor = Nx.tensor([1, 2, 3])
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >

      iex> tensor = Nx.tensor([1.0, 2.0, 3.0], type: :f64)
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        Polars[3]
        float [1.0, 2.0, 3.0]
      >

  Unsigned 8-bit tensors are assumed to be booleans:

      iex> tensor = Nx.tensor([1, 0, 1], type: :u8)
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        Polars[3]
        boolean [true, false, true]
      >

  Signed 32-bit tensors are assumed to be dates:

      iex> tensor = Nx.tensor([-719162, 0, 6129], type: :s32)
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        Polars[3]
        date [0001-01-01, 1970-01-01, 1986-10-13]
      >

  Times are signed 64-bit and therefore must have their dtype explicitly given:

      iex> tensor = Nx.tensor([0, 86399999999])
      iex> Explorer.Series.from_tensor(tensor, dtype: :time)
      #Explorer.Series<
        Polars[2]
        time [00:00:00.000000, 23:59:59.999999]
      >

  Datetimes are signed 64-bit and therefore must have their dtype explicitly given:

      iex> tensor = Nx.tensor([0, 529550625987654])
      iex> Explorer.Series.from_tensor(tensor, dtype: :datetime)
      #Explorer.Series<
        Polars[2]
        datetime [1970-01-01 00:00:00.000000, 1986-10-13 01:23:45.987654]
      >
  """
  @doc type: :conversion
  @spec from_tensor(tensor :: Nx.Tensor.t(), opts :: Keyword.t()) :: Series.t()
  def from_tensor(tensor, opts \\ []) when is_struct(tensor, Nx.Tensor) do
    opts = Keyword.validate!(opts, [:dtype, :backend])
    type = Nx.type(tensor)
    {dtype, opts} = Keyword.pop_lazy(opts, :dtype, fn -> Shared.iotype_to_dtype!(type) end)

    if Shared.dtype_to_iotype!(dtype) != type do
      raise ArgumentError,
            "dtype #{dtype} expects a tensor of type #{inspect(Shared.dtype_to_iotype!(dtype))} " <>
              "but got type #{inspect(type)}"
    end

    backend = backend_from_options!(opts)
    tensor |> Nx.to_binary() |> backend.from_binary(dtype)
  end

  @doc """
  Replaces the contents of the given series by the one given in
  a tensor or list.

  The new series will have the same dtype and backend as the current
  series, but the size may not necessarily match.

  ## Tensor examples

      iex> s = Explorer.Series.from_list([0, 1, 2])
      iex> Explorer.Series.replace(s, Nx.tensor([1, 2, 3]))
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >

  This is particularly useful for categorical columns:

      iex> s = Explorer.Series.from_list(["foo", "bar", "baz"], dtype: :category)
      iex> Explorer.Series.replace(s, Nx.tensor([2, 1, 0]))
      #Explorer.Series<
        Polars[3]
        category ["baz", "bar", "foo"]
      >

  ## List examples

  Similar to tensors, we can also replace by lists:

      iex> s = Explorer.Series.from_list([0, 1, 2])
      iex> Explorer.Series.replace(s, [1, 2, 3, 4, 5])
      #Explorer.Series<
        Polars[5]
        integer [1, 2, 3, 4, 5]
      >

  The same considerations as above apply.
  """
  @doc type: :conversion
  @spec replace(Series.t(), Nx.Tensor.t() | list()) :: Series.t()
  def replace(series, tensor_or_list)

  def replace(series, tensor) when is_struct(tensor, Nx.Tensor) do
    replace(series, :from_tensor, tensor)
  end

  def replace(series, list) when is_list(list) do
    replace(series, :from_list, list)
  end

  defp replace(series, fun, arg) do
    backend_series_string = Atom.to_string(series.data.__struct__)
    backend_string = binary_part(backend_series_string, 0, byte_size(backend_series_string) - 7)
    backend = String.to_atom(backend_string)

    case series.dtype do
      :category ->
        Series
        |> apply(fun, [arg, [dtype: :integer, backend: backend]])
        |> categorise(series)

      dtype ->
        apply(Series, fun, [arg, [dtype: dtype, backend: backend]])
    end
  end

  @doc """
  Converts a series to a list.

  > #### Warning {: .warning}
  >
  > You must avoid converting a series to list, as that requires copying
  > the whole series in memory. Prefer to use the operations in this module
  > rather than the ones in `Enum` whenever possible, as this module is
  > optimized for large series.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_list(series)
      [1, 2, 3]
  """
  @doc type: :conversion
  @spec to_list(series :: Series.t()) :: list()
  def to_list(series), do: apply_series(series, :to_list)

  @doc """
  Converts a series to an enumerable.

  The enumerable will lazily traverse the series.

  > #### Warning {: .warning}
  >
  > You must avoid converting a series to enum, as that will copy the whole
  > series in memory as you traverse it. Prefer to use the operations in this
  > module rather than the ones in `Enum` whenever possible, as this module is
  > optimized for large series.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> series |> Explorer.Series.to_enum() |> Enum.to_list()
      [1, 2, 3]
  """
  @doc type: :conversion
  @spec to_enum(series :: Series.t()) :: Enumerable.t()
  def to_enum(series), do: Explorer.Series.Iterator.new(series)

  @doc """
  Returns a series as a list of fixed-width binaries.

  An io vector (`iovec`) is the Erlang VM term for a flat list of binaries.
  This is typically a reference to the in-memory representation of the series.
  If the whole series in contiguous in memory, then the list will have a single
  element. All binaries are in native endianness.

  This operation fails if the series has `nil` values.
  Use `fill_missing/1` to handle them accordingly.

  To retrieve the type of the underlying io vector, use `iotype/1`.
  To convert an iovec to a binary, you can use `IO.iodata_to_binary/1`.

  ## Examples

  Integers and floats follow their native encoding:

      iex> series = Explorer.Series.from_list([-1, 0, 1])
      iex> Explorer.Series.to_iovec(series)
      [<<-1::signed-64-native, 0::signed-64-native, 1::signed-64-native>>]

      iex> series = Explorer.Series.from_list([1.0, 2.0, 3.0])
      iex> Explorer.Series.to_iovec(series)
      [<<1.0::float-64-native, 2.0::float-64-native, 3.0::float-64-native>>]

  Booleans are encoded as 0 and 1:

      iex> series = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.to_iovec(series)
      [<<1, 0, 1>>]

  Dates are encoded as i32 representing days from the Unix epoch (1970-01-01):

      iex> series = Explorer.Series.from_list([~D[0001-01-01], ~D[1970-01-01], ~D[1986-10-13]])
      iex> Explorer.Series.to_iovec(series)
      [<<-719162::signed-32-native, 0::signed-32-native, 6129::signed-32-native>>]

  Times are encoded as i64 representing microseconds from midnight:

      iex> series = Explorer.Series.from_list([~T[00:00:00.000000], ~T[23:59:59.999999]])
      iex> Explorer.Series.to_iovec(series)
      [<<0::signed-64-native, 86399999999::signed-64-native>>]

  Datetimes are encoded as i64 representing microseconds from the Unix epoch (1970-01-01):

      iex> series = Explorer.Series.from_list([~N[0001-01-01 00:00:00], ~N[1970-01-01 00:00:00], ~N[1986-10-13 01:23:45.987654]])
      iex> Explorer.Series.to_iovec(series)
      [<<-62135596800000000::signed-64-native, 0::signed-64-native, 529550625987654::signed-64-native>>]

  The operation raises for binaries and strings, as they do not provide a fixed-width
  binary representation:

      iex> s = Explorer.Series.from_list(["a", "b", "c", "b"])
      iex> Explorer.Series.to_iovec(s)
      ** (ArgumentError) cannot convert series of dtype :string into iovec

  However, if appropriate, you can convert them to categorical types,
  which will then return the index of each category:

      iex> series = Explorer.Series.from_list(["a", "b", "c", "b"], dtype: :category)
      iex> Explorer.Series.to_iovec(series)
      [<<0::unsigned-32-native, 1::unsigned-32-native, 2::unsigned-32-native, 1::unsigned-32-native>>]

  """
  @doc type: :conversion
  @spec to_iovec(series :: Series.t()) :: [binary]
  def to_iovec(%Series{dtype: dtype} = series) do
    if is_io_dtype(dtype) do
      apply_series(series, :to_iovec)
    else
      raise ArgumentError, "cannot convert series of dtype #{inspect(dtype)} into iovec"
    end
  end

  @doc """
  Returns a series as a fixed-width binary.

  This is a shortcut around `to_iovec/1`. If possible, prefer
  to use `to_iovec/1` as that avoids copying binaries.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_binary(series)
      <<1::signed-64-native, 2::signed-64-native, 3::signed-64-native>>

      iex> series = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.to_binary(series)
      <<1, 0, 1>>

  """
  @doc type: :conversion
  @spec to_binary(series :: Series.t()) :: binary
  def to_binary(series), do: series |> to_iovec() |> IO.iodata_to_binary()

  @doc """
  Converts a series to a `t:Nx.Tensor.t/0`.

  Note that `Explorer.Series` are automatically converted
  to tensors when passed to numerical definitions.
  The tensor type is given by `iotype/1`.

  > #### Warning {: .warning}
  >
  > `Nx` is an optional dependency. You will need to ensure it's installed to use this function.

  ## Options

    * `:backend` - the Nx backend to allocate the tensor on

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_tensor(s)
      #Nx.Tensor<
        s64[3]
        [1, 2, 3]
      >

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.to_tensor(s)
      #Nx.Tensor<
        u8[3]
        [1, 0, 1]
      >

  """
  @doc type: :conversion
  @spec to_tensor(series :: Series.t(), tensor_opts :: Keyword.t()) :: Nx.Tensor.t()
  def to_tensor(%Series{dtype: dtype} = series, tensor_opts \\ []) do
    case iotype(series) do
      {_, _} = type ->
        Nx.from_binary(to_binary(series), type, tensor_opts)

      :none when Kernel.in(dtype, [:string, :binary]) ->
        raise ArgumentError,
              "cannot convert #{inspect(dtype)} series to tensor (consider casting the series to a :category type before)"

      :none ->
        raise ArgumentError, "cannot convert #{inspect(dtype)} series to tensor"
    end
  end

  @doc """
  Cast the series to another type.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :string)
      #Explorer.Series<
        Polars[3]
        string ["1", "2", "3"]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :float)
      #Explorer.Series<
        Polars[3]
        float [1.0, 2.0, 3.0]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :date)
      #Explorer.Series<
        Polars[3]
        date [1970-01-02, 1970-01-03, 1970-01-04]
      >

  Note that `time` is represented as an integer of microseconds since midnight.

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :time)
      #Explorer.Series<
        Polars[3]
        time [00:00:00.000001, 00:00:00.000002, 00:00:00.000003]
      >

      iex> s = Explorer.Series.from_list([86399 * 1_000 * 1_000])
      iex> Explorer.Series.cast(s, :time)
      #Explorer.Series<
        Polars[1]
        time [23:59:59.000000]
      >

  Note that `datetime` is represented as an integer of microseconds since Unix Epoch (1970-01-01 00:00:00).

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :datetime)
      #Explorer.Series<
        Polars[3]
        datetime [1970-01-01 00:00:00.000001, 1970-01-01 00:00:00.000002, 1970-01-01 00:00:00.000003]
      >

      iex> s = Explorer.Series.from_list([1649883642 * 1_000 * 1_000])
      iex> Explorer.Series.cast(s, :datetime)
      #Explorer.Series<
        Polars[1]
        datetime [2022-04-13 21:00:42.000000]
      >

  You can also use `cast/2` to categorise a string:

      iex> s = Explorer.Series.from_list(["apple", "banana",  "apple", "lemon"])
      iex> Explorer.Series.cast(s, :category)
      #Explorer.Series<
        Polars[4]
        category ["apple", "banana", "apple", "lemon"]
      >

  `cast/2` will return the series as a no-op if you try to cast to the same dtype.

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :integer)
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >
  """
  @doc type: :element_wise
  @spec cast(series :: Series.t(), dtype :: dtype()) :: Series.t()
  def cast(%Series{dtype: dtype} = series, dtype), do: series

  def cast(series, dtype) when K.in(dtype, @valid_dtypes),
    do: apply_series(series, :cast, [dtype])

  def cast(_series, dtype), do: dtype_error("cast/2", dtype, @valid_dtypes)

  # Introspection

  @doc """
  Returns the data type of the series.

  A series can be of the following data types:

    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:boolean` - Boolean
    * `:string` - UTF-8 encoded binary
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:time` - Time type that unwraps to `Elixir.Time`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.dtype(s)
      :integer

      iex> s = Explorer.Series.from_list(["a", nil, "b", "c"])
      iex> Explorer.Series.dtype(s)
      :string
  """
  @doc type: :introspection
  @spec dtype(series :: Series.t()) :: dtype()
  def dtype(%Series{dtype: dtype}), do: dtype

  @doc """
  Returns the size of the series.

  This is not allowed inside a lazy series. Use `count/1` instead.

  ## Examples

      iex> s = Explorer.Series.from_list([~D[1999-12-31], ~D[1989-01-01]])
      iex> Explorer.Series.size(s)
      2
  """
  @doc type: :introspection
  @spec size(series :: Series.t()) :: non_neg_integer() | lazy_t()
  def size(series), do: apply_series(series, :size)

  @doc """
  Returns the type of the underlying fixed-width binary representation.

  It returns something in the shape of `{atom(), bits_size}` or `:none`.
  It is often used in conjunction with `to_iovec/1` and `to_binary/1`.

  The possible iotypes are:

  * `:u` for unsigned integers.
  * `:s` for signed integers.
  * `:f` for floats.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3, 4])
      iex> Explorer.Series.iotype(s)
      {:s, 64}

      iex> s = Explorer.Series.from_list([~D[1999-12-31], ~D[1989-01-01]])
      iex> Explorer.Series.iotype(s)
      {:s, 32}

      iex> s = Explorer.Series.from_list([~T[00:00:00.000000], ~T[23:59:59.999999]])
      iex> Explorer.Series.iotype(s)
      {:s, 64}

      iex> s = Explorer.Series.from_list([1.2, 2.3, 3.5, 4.5])
      iex> Explorer.Series.iotype(s)
      {:f, 64}

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.iotype(s)
      {:u, 8}

  The operation returns `:none` for strings and binaries, as they do not
  provide a fixed-width binary representation:

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.iotype(s)
      :none

  However, if appropriate, you can convert them to categorical types,
  which will then return the index of each category:

      iex> s = Explorer.Series.from_list(["a", "b", "c"], dtype: :category)
      iex> Explorer.Series.iotype(s)
      {:u, 32}

  """
  @doc type: :introspection
  @spec iotype(series :: Series.t()) :: {:s | :u | :f, non_neg_integer()} | :none
  def iotype(%Series{dtype: dtype} = series) do
    if is_io_dtype(dtype) do
      apply_series(series, :iotype)
    else
      :none
    end
  end

  @doc """
  Return a series with the category names of a categorical series.

  Each category has the index equal to its position.
  No order for the categories is guaranteed.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c", nil, "a", "c"], dtype: :category)
      iex> Explorer.Series.categories(s)
      #Explorer.Series<
        Polars[3]
        string ["a", "b", "c"]
      >

      iex> s = Explorer.Series.from_list(["c", "a", "b"], dtype: :category)
      iex> Explorer.Series.categories(s)
      #Explorer.Series<
        Polars[3]
        string ["c", "a", "b"]
      >

  """
  @doc type: :introspection
  @spec categories(series :: Series.t()) :: Series.t()
  def categories(%Series{dtype: :category} = series), do: apply_series(series, :categories)
  def categories(%Series{dtype: dtype}), do: dtype_error("categories/1", dtype, [:category])

  @doc """
  Categorise a series of integers according to `categories`.

  This function receives a series of integers and convert them into the
  categories specified by the second argument. The second argument can
  be one of:

    * a series with dtype `:category`. The integers will be indexes into
      the categories of the given series (returned by `categories/1`)

    * a series with dtype `:string`. The integers will be indexes into
      the series itself

    * a list of strings. The integers will be indexes into the list

  If you have a series of strings and you want to convert them into categories,
  invoke `cast(series, :category)` instead.

  ## Examples

  If a categorical series is given as second argument, we will extract its
  categories and map the integers into it:

      iex> categories = Explorer.Series.from_list(["a", "b", "c", nil, "a"], dtype: :category)
      iex> indexes = Explorer.Series.from_list([0, 2, 1, 0, 2])
      iex> Explorer.Series.categorise(indexes, categories)
      #Explorer.Series<
        Polars[5]
        category ["a", "c", "b", "a", "c"]
      >

  Otherwise, if a list of strings or a series of strings is given, they are
  considered to be the categories series itself:

      iex> categories = Explorer.Series.from_list(["a", "b", "c"])
      iex> indexes = Explorer.Series.from_list([0, 2, 1, 0, 2])
      iex> Explorer.Series.categorise(indexes, categories)
      #Explorer.Series<
        Polars[5]
        category ["a", "c", "b", "a", "c"]
      >

      iex> indexes = Explorer.Series.from_list([0, 2, 1, 0, 2])
      iex> Explorer.Series.categorise(indexes, ["a", "b", "c"])
      #Explorer.Series<
        Polars[5]
        category ["a", "c", "b", "a", "c"]
      >

  Elements that are not mapped to a category will become `nil`:

      iex> indexes = Explorer.Series.from_list([0, 2, nil, 0, 2, 7])
      iex> Explorer.Series.categorise(indexes, ["a", "b", "c"])
      #Explorer.Series<
        Polars[6]
        category ["a", "c", nil, "a", "c", nil]
      >

  """
  @doc type: :element_wise
  def categorise(%Series{dtype: :integer} = series, %Series{dtype: dtype} = categories)
      when K.in(dtype, [:string, :category]),
      do: apply_series(series, :categorise, [categories])

  def categorise(%Series{dtype: :integer} = series, [head | _] = categories) when is_binary(head),
    do: apply_series(series, :categorise, [from_list(categories, dtype: :string)])

  # Slice and dice

  @doc """
  Returns the first N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.head(s)
      #Explorer.Series<
        Polars[10]
        integer [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      >
  """
  @doc type: :shape
  @spec head(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def head(series, n_elements \\ 10), do: apply_series(series, :head, [n_elements])

  @doc """
  Returns the last N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.tail(s)
      #Explorer.Series<
        Polars[10]
        integer [91, 92, 93, 94, 95, 96, 97, 98, 99, 100]
      >
  """
  @doc type: :shape
  @spec tail(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def tail(series, n_elements \\ 10), do: apply_series(series, :tail, [n_elements])

  @doc """
  Returns the first element of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.first(s)
      1
  """
  @doc type: :shape
  @spec first(series :: Series.t()) :: any()
  def first(series), do: apply_series(series, :first, [])

  @doc """
  Returns the last element of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.last(s)
      100
  """
  @doc type: :shape
  @spec last(series :: Series.t()) :: any()
  def last(series), do: apply_series(series, :last, [])

  @doc """
  Shifts `series` by `offset` with `nil` values.

  Positive offset shifts from first, negative offset shifts from last.

  ## Examples

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.shift(s, 2)
      #Explorer.Series<
        Polars[5]
        integer [nil, nil, 1, 2, 3]
      >

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.shift(s, -2)
      #Explorer.Series<
        Polars[5]
        integer [3, 4, 5, nil, nil]
      >
  """
  @doc type: :shape
  @spec shift(series :: Series.t(), offset :: integer()) :: Series.t()
  def shift(series, offset)
      when is_integer(offset),
      do: apply_series(series, :shift, [offset, nil])

  @doc """
  Returns a series from two series, based on a predicate.

  The resulting series is built by evaluating each element of
  `predicate` and returning either the corresponding element from
  `on_true` or `on_false`.

  `predicate` must be a boolean series. `on_true` and `on_false` must be
  a series of the same size as `predicate` or a series of size 1.
  """
  @doc type: :element_wise
  @spec select(predicate :: Series.t(), on_true :: Series.t(), on_false :: Series.t()) ::
          Series.t()
  def select(
        %Series{dtype: predicate_dtype} = predicate,
        %Series{dtype: on_true_dtype} = on_true,
        %Series{dtype: on_false_dtype} = on_false
      ) do
    if predicate_dtype != :boolean do
      raise ArgumentError,
            "Explorer.Series.select/3 expect the first argument to be a series of booleans, got: #{inspect(predicate_dtype)}"
    end

    cond do
      K.and(is_numeric_dtype(on_true_dtype), is_numeric_dtype(on_false_dtype)) ->
        apply_series_list(:select, [predicate, on_true, on_false])

      on_true_dtype == on_false_dtype ->
        apply_series_list(:select, [predicate, on_true, on_false])

      true ->
        dtype_mismatch_error("select/3", on_true_dtype, on_false_dtype)
    end
  end

  @doc """
  Returns a random sample of the series.

  If given an integer as the second argument, it will return N samples. If given a float, it will
  return that proportion of the series.

  Can sample with or without replace.

  ## Options

    * `:replace` - If set to `true`, each sample will be independent and therefore values may repeat.
      Required to be `true` for `n` greater then the number of rows in the series or `frac` > 1.0. (default: `false`)
    * `:seed` - An integer to be used as a random seed. If nil, a random value between 0 and 2^64 − 1 will be used. (default: nil)
    * `:shuffle` - In case the sample is equal to the size of the series, shuffle tells if the resultant
      series should be shuffled or if it should return the same series. (default: `false`).

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 10, seed: 100)
      #Explorer.Series<
        Polars[10]
        integer [55, 51, 33, 26, 5, 32, 62, 31, 9, 25]
      >

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 0.05, seed: 100)
      #Explorer.Series<
        Polars[5]
        integer [49, 77, 96, 19, 18]
      >

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 7, seed: 100, replace: true)
      #Explorer.Series<
        Polars[7]
        integer [4, 1, 3, 4, 3, 4, 2]
      >

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 1.2, seed: 100, replace: true)
      #Explorer.Series<
        Polars[6]
        integer [4, 1, 3, 4, 3, 4]
      >

      iex> s = 0..9 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 1.0, seed: 100, shuffle: false)
      #Explorer.Series<
        Polars[10]
        integer [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
      >

      iex> s = 0..9 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 1.0, seed: 100, shuffle: true)
      #Explorer.Series<
        Polars[10]
        integer [7, 9, 2, 0, 4, 1, 3, 8, 5, 6]
      >

  """
  @doc type: :shape
  @spec sample(series :: Series.t(), n_or_frac :: number(), opts :: Keyword.t()) :: Series.t()
  def sample(series, n_or_frac, opts \\ []) when is_number(n_or_frac) do
    opts = Keyword.validate!(opts, replace: false, shuffle: false, seed: nil)

    size = size(series)

    # In case the series is lazy, we don't perform this check here.
    if K.and(
         is_integer(size),
         K.and(opts[:replace] == false, invalid_size_for_sample?(n_or_frac, size))
       ) do
      raise ArgumentError,
            "in order to sample more elements than are in the series (#{size}), sampling " <>
              "`replace` must be true"
    end

    apply_series(series, :sample, [n_or_frac, opts[:replace], opts[:shuffle], opts[:seed]])
  end

  defp invalid_size_for_sample?(n, size) when is_integer(n), do: n > size

  defp invalid_size_for_sample?(frac, size) when is_float(frac),
    do: invalid_size_for_sample?(round(frac * size), size)

  @doc """
  Change the elements order randomly.

  ## Options

    * `:seed` - An integer to be used as a random seed. If nil,
      a random value between 0 and 2^64 − 1 will be used. (default: nil)

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.shuffle(s, seed: 100)
      #Explorer.Series<
        Polars[10]
        integer [8, 10, 3, 1, 5, 2, 4, 9, 6, 7]
      >

  """
  @doc type: :shape
  @spec shuffle(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def shuffle(series, opts \\ [])

  def shuffle(series, opts) do
    opts = Keyword.validate!(opts, seed: nil)

    sample(series, 1.0, seed: opts[:seed], shuffle: true)
  end

  @doc """
  Takes every *n*th value in this series, returned as a new series.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.at_every(s, 2)
      #Explorer.Series<
        Polars[5]
        integer [1, 3, 5, 7, 9]
      >

  If *n* is bigger than the size of the series, the result is a new series with only the first value of the supplied series.

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.at_every(s, 20)
      #Explorer.Series<
        Polars[1]
        integer [1]
      >
  """
  @doc type: :shape
  @spec at_every(series :: Series.t(), every_n :: integer()) :: Series.t()
  def at_every(series, every_n), do: apply_series(series, :at_every, [every_n])

  @doc """
  Filters a series with a mask.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1,2,3])
      iex> s2 = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.mask(s1, s2)
      #Explorer.Series<
        Polars[2]
        integer [1, 3]
      >
  """
  @doc type: :element_wise
  @spec mask(series :: Series.t(), mask :: Series.t()) :: Series.t()
  def mask(series, %Series{} = mask), do: apply_series(series, :mask, [mask])

  @doc """
  Returns a slice of the series, with `size` elements starting at `offset`.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, 1, 2)
      #Explorer.Series<
        Polars[2]
        integer [2, 3]
      >

  Negative offsets count from the end of the series:

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 2)
      #Explorer.Series<
        Polars[2]
        integer [3, 4]
      >

  If the offset runs past the end of the series,
  the series is empty:

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, 10, 3)
      #Explorer.Series<
        Polars[0]
        integer []
      >

  If the size runs past the end of the series,
  the result may be shorter than the size:

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 4)
      #Explorer.Series<
        Polars[3]
        integer [3, 4, 5]
      >
  """
  @doc type: :shape
  @spec slice(series :: Series.t(), offset :: integer(), size :: integer()) :: Series.t()
  def slice(series, offset, size), do: apply_series(series, :slice, [offset, size])

  @doc """
  Slices the elements at the given indices as a new series.

  The indices may be either a list of indices or a range.
  A list of indices does not support negative numbers.
  Ranges may be negative on either end, which are then
  normalized. Note ranges in Elixir are inclusive.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, [0, 2])
      #Explorer.Series<
        Polars[2]
        string ["a", "c"]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, 1..2)
      #Explorer.Series<
        Polars[2]
        string ["b", "c"]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, -2..-1)
      #Explorer.Series<
        Polars[2]
        string ["b", "c"]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, 3..2)
      #Explorer.Series<
        Polars[0]
        string []
      >

  """
  @doc type: :shape
  @spec slice(series :: Series.t(), indices :: [integer()] | Range.t() | Series.t()) :: Series.t()
  def slice(series, indices) when is_list(indices),
    do: apply_series(series, :slice, [indices])

  def slice(series, %Series{dtype: :integer} = indices),
    do: apply_series(series, :slice, [indices])

  def slice(_series, %Series{dtype: invalid_dtype}),
    do: dtype_error("slice/2", invalid_dtype, [:integer])

  def slice(series, first..last//1) do
    first = if first < 0, do: first + size(series), else: first
    last = if last < 0, do: last + size(series), else: last
    size = last - first + 1

    if K.and(first >= 0, size >= 0) do
      apply_series(series, :slice, [first, size])
    else
      apply_series(series, :slice, [[]])
    end
  end

  def slice(series, %Range{} = range),
    do: slice(series, Enum.slice(0..(size(series) - 1)//1, range))

  @doc """
  Returns the value of the series at the given index.

  This function will raise an error in case the index
  is out of bounds.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.at(s, 2)
      "c"

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.at(s, 4)
      ** (ArgumentError) index 4 out of bounds for series of size 3
  """
  @doc type: :shape
  @spec at(series :: Series.t(), idx :: integer()) :: any()
  def at(series, idx), do: fetch!(series, idx)

  @doc """
  Returns a string series with all values concatenated.

  ## Examples

      iex> s1 = Explorer.Series.from_list(["a", "b", "c"])
      iex> s2 = Explorer.Series.from_list(["d", "e", "f"])
      iex> s3 = Explorer.Series.from_list(["g", "h", "i"])
      iex> Explorer.Series.format([s1, s2, s3])
      #Explorer.Series<
        Polars[3]
        string ["adg", "beh", "cfi"]
      >

      iex> s1 = Explorer.Series.from_list(["a", "b", "c", "d"])
      iex> s2 = Explorer.Series.from_list([1, 2, 3, 4])
      iex> s3 = Explorer.Series.from_list([1.5, :nan, :infinity, :neg_infinity])
      iex> Explorer.Series.format([s1, "/", s2, "/", s3])
      #Explorer.Series<
        Polars[4]
        string ["a/1/1.5", "b/2/NaN", "c/3/inf", "d/4/-inf"]
      >

      iex> s1 = Explorer.Series.from_list([<<1>>, <<239, 191, 19>>], dtype: :binary)
      iex> s2 = Explorer.Series.from_list([<<3>>, <<4>>], dtype: :binary)
      iex> Explorer.Series.format([s1, s2])
      ** (RuntimeError) External error: invalid utf-8 sequence
  """
  @doc type: :shape
  @spec format([Series.t() | String.t()]) :: Series.t()
  def format([_ | _] = list) do
    list = cast_to_string(list)
    impl!(list).format(list)
  end

  defp cast_to_string(list) do
    Enum.map(list, fn
      %Series{dtype: :string} = s ->
        s

      %Series{} = s ->
        cast(s, :string)

      value when is_binary(value) ->
        from_list([value], dtype: :string)

      other ->
        raise ArgumentError,
              "format/1 expects a list of series or strings, got: #{inspect(other)}"
    end)
  end

  @doc """
  Concatenate one or more series.

  The dtypes must match unless all are numeric, in which case all series will be downcast to float.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.concat([s1, s2])
      #Explorer.Series<
        Polars[6]
        integer [1, 2, 3, 4, 5, 6]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4.0, 5.0, 6.4])
      iex> Explorer.Series.concat([s1, s2])
      #Explorer.Series<
        Polars[6]
        float [1.0, 2.0, 3.0, 4.0, 5.0, 6.4]
      >
  """
  @doc type: :shape
  @spec concat([Series.t()]) :: Series.t()
  def concat([%Series{} | _t] = series) do
    dtypes = series |> Enum.map(& &1.dtype) |> Enum.uniq()

    case dtypes do
      [_dtype] ->
        impl!(series).concat(series)

      [a, b] when K.and(is_numeric_dtype(a), is_numeric_dtype(b)) ->
        series = Enum.map(series, &cast(&1, :float))
        impl!(series).concat(series)

      incompatible ->
        raise ArgumentError,
              "cannot concatenate series with mismatched dtypes: #{inspect(incompatible)}. " <>
                "First cast the series to the desired dtype."
    end
  end

  @doc """
  Concatenate two series.

  `concat(s1, s2)` is equivalent to `concat([s1, s2])`.
  """
  @doc type: :shape
  @spec concat(s1 :: Series.t(), s2 :: Series.t()) :: Series.t()
  def concat(%Series{} = s1, %Series{} = s2),
    do: concat([s1, s2])

  @doc """
  Finds the first non-missing element at each position.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, nil, nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> s3 = Explorer.Series.from_list([nil, nil, 3, 4])
      iex> Explorer.Series.coalesce([s1, s2, s3])
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 3, 4]
      >
  """
  @doc type: :element_wise
  @spec coalesce([Series.t()]) :: Series.t()
  def coalesce([%Series{} = h | t]),
    do: Enum.reduce(t, h, &coalesce(&2, &1))

  @doc """
  Finds the first non-missing element at each position.

  `coalesce(s1, s2)` is equivalent to `coalesce([s1, s2])`.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, nil, 3, nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.coalesce(s1, s2)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 3, 4]
      >

      iex> s1 = Explorer.Series.from_list(["foo", nil, "bar", nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.coalesce(s1, s2)
      ** (ArgumentError) cannot invoke Explorer.Series.coalesce/2 with mismatched dtypes: :string and :integer
  """
  @doc type: :element_wise
  @spec coalesce(s1 :: Series.t(), s2 :: Series.t()) :: Series.t()
  def coalesce(s1, s2) do
    :ok = check_dtypes_for_coalesce!(s1, s2)
    apply_series_list(:coalesce, [s1, s2])
  end

  # Aggregation

  @doc """
  Gets the sum of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.sum(s)
      6

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.sum(s)
      6.0

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.sum(s)
      2

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.sum(s)
      ** (ArgumentError) Explorer.Series.sum/1 not implemented for dtype :date. Valid dtypes are [:integer, :float, :boolean]
  """
  @doc type: :aggregation
  @spec sum(series :: Series.t()) :: number() | non_finite() | nil
  def sum(%Series{dtype: dtype} = series) when is_numeric_or_bool_dtype(dtype),
    do: apply_series(series, :sum)

  def sum(%Series{dtype: dtype}), do: dtype_error("sum/1", dtype, [:integer, :float, :boolean])

  @doc """
  Gets the minimum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.min(s)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.min(s)
      1.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.min(s)
      ~D[1999-12-31]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.min(s)
      ~N[1999-12-31 00:00:00.000000]

      iex> s = Explorer.Series.from_list([~T[00:02:03.000000], ~T[00:05:04.000000]])
      iex> Explorer.Series.min(s)
      ~T[00:02:03.000000]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.min(s)
      ** (ArgumentError) Explorer.Series.min/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :time, :datetime]
  """
  @doc type: :aggregation
  @spec min(series :: Series.t()) ::
          number() | non_finite() | Date.t() | Time.t() | NaiveDateTime.t() | nil
  def min(%Series{dtype: dtype} = series) when is_numeric_or_date_dtype(dtype),
    do: apply_series(series, :min)

  def min(%Series{dtype: dtype}),
    do: dtype_error("min/1", dtype, [:integer, :float, :date, :time, :datetime])

  @doc """
  Gets the maximum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.max(s)
      3

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.max(s)
      3.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.max(s)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.max(s)
      ~N[2021-01-01 00:00:00.000000]

      iex> s = Explorer.Series.from_list([~T[00:02:03.000000], ~T[00:05:04.000000]])
      iex> Explorer.Series.max(s)
      ~T[00:05:04.000000]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.max(s)
      ** (ArgumentError) Explorer.Series.max/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :time, :datetime]
  """
  @doc type: :aggregation
  @spec max(series :: Series.t()) ::
          number() | non_finite() | Date.t() | Time.t() | NaiveDateTime.t() | nil
  def max(%Series{dtype: dtype} = series) when is_numeric_or_date_dtype(dtype),
    do: apply_series(series, :max)

  def max(%Series{dtype: dtype}),
    do: dtype_error("max/1", dtype, [:integer, :float, :date, :time, :datetime])

  @doc """
  Gets the mean value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.mean(s)
      ** (ArgumentError) Explorer.Series.mean/1 not implemented for dtype :date. Valid dtypes are [:integer, :float]
  """
  @doc type: :aggregation
  @spec mean(series :: Series.t()) :: float() | non_finite() | nil
  def mean(%Series{dtype: dtype} = series) when is_numeric_dtype(dtype),
    do: apply_series(series, :mean)

  def mean(%Series{dtype: dtype}), do: dtype_error("mean/1", dtype, [:integer, :float])

  @doc """
  Gets the median value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.median(s)
      ** (ArgumentError) Explorer.Series.median/1 not implemented for dtype :date. Valid dtypes are [:integer, :float]
  """
  @doc type: :aggregation
  @spec median(series :: Series.t()) :: float() | non_finite() | nil
  def median(%Series{dtype: dtype} = series) when is_numeric_dtype(dtype),
    do: apply_series(series, :median)

  def median(%Series{dtype: dtype}), do: dtype_error("median/1", dtype, [:integer, :float])

  @doc """
  Gets the variance of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.variance(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.variance(s)
      1.0

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.variance(s)
      ** (ArgumentError) Explorer.Series.variance/1 not implemented for dtype :datetime. Valid dtypes are [:integer, :float]
  """
  @doc type: :aggregation
  @spec variance(series :: Series.t()) :: float() | non_finite() | nil
  def variance(%Series{dtype: dtype} = series) when is_numeric_dtype(dtype),
    do: apply_series(series, :variance)

  def variance(%Series{dtype: dtype}), do: dtype_error("variance/1", dtype, [:integer, :float])

  @doc """
  Gets the standard deviation of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.standard_deviation(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.standard_deviation(s)
      1.0

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.standard_deviation(s)
      ** (ArgumentError) Explorer.Series.standard_deviation/1 not implemented for dtype :string. Valid dtypes are [:integer, :float]
  """
  @doc type: :aggregation
  @spec standard_deviation(series :: Series.t()) :: float() | non_finite() | nil
  def standard_deviation(%Series{dtype: dtype} = series) when is_numeric_dtype(dtype),
    do: apply_series(series, :standard_deviation)

  def standard_deviation(%Series{dtype: dtype}),
    do: dtype_error("standard_deviation/1", dtype, [:integer, :float])

  @doc """
  Gets the given quantile of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.quantile(s, 0.2)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.quantile(s, 0.5)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~N[2021-01-01 00:00:00.000000]

      iex> s = Explorer.Series.from_list([~T[01:55:00.000000], ~T[15:35:00.000000], ~T[23:00:00.000000]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~T[15:35:00.000000]

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.quantile(s, 0.5)
      ** (ArgumentError) Explorer.Series.quantile/2 not implemented for dtype :boolean. Valid dtypes are [:integer, :float, :date, :time, :datetime]
  """
  @doc type: :aggregation
  @spec quantile(series :: Series.t(), quantile :: float()) :: any()
  def quantile(%Series{dtype: dtype} = series, quantile)
      when is_numeric_or_date_dtype(dtype),
      do: apply_series(series, :quantile, [quantile])

  def quantile(%Series{dtype: dtype}, _),
    do: dtype_error("quantile/2", dtype, [:integer, :float, :date, :time, :datetime])

  # Cumulative

  @doc """
  Calculates the cumulative maximum of the series.

  Optionally, can accumulate in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_max(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 3, 4]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_max(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, nil, 4]
      >

      iex> s = [~T[03:00:02.000000], ~T[02:04:19.000000], nil, ~T[13:24:56.000000]] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_max(s)
      #Explorer.Series<
        Polars[4]
        time [03:00:02.000000, 03:00:02.000000, nil, 13:24:56.000000]
      >
  """
  @doc type: :window
  @spec cumulative_max(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_max(series, opts \\ [])

  def cumulative_max(%Series{dtype: dtype} = series, opts)
      when is_numeric_or_date_dtype(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    apply_series(series, :cumulative_max, [opts[:reverse]])
  end

  def cumulative_max(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_max/2", dtype, [:integer, :float, :date, :time, :datetime])

  @doc """
  Calculates the cumulative minimum of the series.

  Optionally, can accumulate in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_min(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 1, 1, 1]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_min(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 1, nil, 1]
      >

      iex> s = [~T[03:00:02.000000], ~T[02:04:19.000000], nil, ~T[13:24:56.000000]] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_min(s)
      #Explorer.Series<
        Polars[4]
        time [03:00:02.000000, 02:04:19.000000, nil, 02:04:19.000000]
      >
  """
  @doc type: :window
  @spec cumulative_min(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_min(series, opts \\ [])

  def cumulative_min(%Series{dtype: dtype} = series, opts)
      when is_numeric_or_date_dtype(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    apply_series(series, :cumulative_min, [opts[:reverse]])
  end

  def cumulative_min(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_min/2", dtype, [:integer, :float, :date, :time, :datetime])

  @doc """
  Calculates the cumulative sum of the series.

  Optionally, can accumulate in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_sum(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 3, 6, 10]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_sum(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 3, nil, 7]
      >
  """
  @doc type: :window
  @spec cumulative_sum(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_sum(series, opts \\ [])

  def cumulative_sum(%Series{dtype: dtype} = series, opts)
      when is_numeric_dtype(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    apply_series(series, :cumulative_sum, [opts[:reverse]])
  end

  def cumulative_sum(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_sum/2", dtype, [:integer, :float])

  # Local minima/maxima

  @doc """
  Returns a boolean mask with `true` where the 'peaks' (series max or min, default max) are.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 4, 1, 4])
      iex> Explorer.Series.peaks(s)
      #Explorer.Series<
        Polars[5]
        boolean [false, false, true, false, true]
      >

      iex> s = [~T[03:00:02.000000], ~T[13:24:56.000000], ~T[02:04:19.000000]] |> Explorer.Series.from_list()
      iex> Explorer.Series.peaks(s)
      #Explorer.Series<
        Polars[3]
        boolean [false, true, false]
      >
  """
  @doc type: :element_wise
  @spec peaks(series :: Series.t(), max_or_min :: :max | :min) :: Series.t()
  def peaks(series, max_or_min \\ :max)

  def peaks(%Series{dtype: dtype} = series, max_or_min)
      when is_numeric_or_date_dtype(dtype),
      do: apply_series(series, :peaks, [max_or_min])

  def peaks(%Series{dtype: dtype}, _),
    do: dtype_error("peaks/2", dtype, [:integer, :float, :date, :time, :datetime])

  # Arithmetic

  @doc """
  Adds right to left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.add(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [5, 7, 9]
      >

  You can also use scalar values on both sides:

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.add(s1, 2)
      #Explorer.Series<
        Polars[3]
        integer [3, 4, 5]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.add(2, s1)
      #Explorer.Series<
        Polars[3]
        integer [3, 4, 5]
      >
  """
  @doc type: :element_wise
  @spec add(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def add(left, right), do: basic_numeric_operation(:add, left, right)

  @doc """
  Subtracts right from left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.subtract(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [-3, -3, -3]
      >

  You can also use scalar values on both sides:

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.subtract(s1, 2)
      #Explorer.Series<
        Polars[3]
        integer [-1, 0, 1]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.subtract(2, s1)
      #Explorer.Series<
        Polars[3]
        integer [1, 0, -1]
      >
  """
  @doc type: :element_wise
  @spec subtract(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def subtract(left, right), do: basic_numeric_operation(:subtract, left, right)

  @doc """
  Multiplies left and right, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> s2 = 11..20 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.multiply(s1, s2)
      #Explorer.Series<
        Polars[10]
        integer [11, 24, 39, 56, 75, 96, 119, 144, 171, 200]
      >

      iex> s1 = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.multiply(s1, 2)
      #Explorer.Series<
        Polars[5]
        integer [2, 4, 6, 8, 10]
      >
  """
  @doc type: :element_wise
  @spec multiply(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def multiply(left, right), do: basic_numeric_operation(:multiply, left, right)

  @doc """
  Divides left by right, element-wise.

  The resulting series will have the dtype as `:float`.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, s2)
      #Explorer.Series<
        Polars[3]
        float [5.0, 5.0, 5.0]
      >

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, 2)
      #Explorer.Series<
        Polars[3]
        float [5.0, 5.0, 5.0]
      >

      iex> s1 = [10, 52 ,10] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, 2.5)
      #Explorer.Series<
        Polars[3]
        float [4.0, 20.8, 4.0]
      >

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 0, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, s2)
      #Explorer.Series<
        Polars[3]
        float [5.0, Inf, 5.0]
      >
  """
  @doc type: :element_wise
  @spec divide(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def divide(left, right), do: basic_numeric_operation(:divide, left, right)

  @doc """
  Raises a numeric series to the power of the exponent.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = [8, 16, 32] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 2.0)
      #Explorer.Series<
        Polars[3]
        float [64.0, 256.0, 1024.0]
      >

      iex> s = [2, 4, 6] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 3)
      #Explorer.Series<
        Polars[3]
        integer [8, 64, 216]
      >

      iex> s = [2, 4, 6] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, -3.0)
      #Explorer.Series<
        Polars[3]
        float [0.125, 0.015625, 0.004629629629629629]
      >

      iex> s = [1.0, 2.0, 3.0] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 3.0)
      #Explorer.Series<
        Polars[3]
        float [1.0, 8.0, 27.0]
      >

      iex> s = [2.0, 4.0, 6.0] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 2)
      #Explorer.Series<
        Polars[3]
        float [4.0, 16.0, 36.0]
      >
  """
  @doc type: :element_wise
  @spec pow(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def pow(left, right), do: basic_numeric_operation(:pow, left, right)

  @doc """
  Calculates the natural logarithm.

  The resultant series is going to be of dtype `:float`.
  See `log/2` for passing a custom base.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3, nil, 4])
      iex> Explorer.Series.log(s)
      #Explorer.Series<
        Polars[5]
        float [0.0, 0.6931471805599453, 1.0986122886681098, nil, 1.3862943611198906]
      >

  """
  @doc type: :element_wise
  @spec log(argument :: Series.t()) :: Series.t()
  def log(%Series{} = s), do: apply_series(s, :log, [])

  @doc """
  Calculates the logarithm on a given base.

  The resultant series is going to be of dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([8, 16, 32])
      iex> Explorer.Series.log(s, 2)
      #Explorer.Series<
        Polars[3]
        float [3.0, 4.0, 5.0]
      >

  """
  @doc type: :element_wise
  @spec log(argument :: Series.t(), base :: number()) :: Series.t()
  def log(argument, base) when is_number(base) do
    if base <= 0, do: raise(ArgumentError, "base must be a positive number")
    if base == 1, do: raise(ArgumentError, "base cannot be equal to 1")

    base = if is_integer(base), do: base / 1.0, else: base

    basic_numeric_operation(:log, argument, base)
  end

  @doc """
  Calculates the exponential of all elements.
  """
  @doc type: :element_wise
  @spec exp(Series.t()) :: Series.t()
  def exp(%Series{} = s), do: apply_series(s, :exp, [])

  @doc """
  Element-wise integer division.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtype

    * `:integer`

  Returns `nil` if there is a zero in the right-hand side.

  ## Examples

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [5, 5, 5]
      >

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 0] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [5, 5, nil]
      >

      iex> s1 = [10, 12, 15] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, 3)
      #Explorer.Series<
        Polars[3]
        integer [3, 4, 5]
      >

  """
  @doc type: :element_wise
  @spec quotient(left :: Series.t(), right :: Series.t() | integer()) :: Series.t()
  def quotient(%Series{dtype: :integer} = left, %Series{dtype: :integer} = right),
    do: apply_series_list(:quotient, [left, right])

  def quotient(%Series{dtype: :integer} = left, right) when is_integer(right),
    do: apply_series_list(:quotient, [left, right])

  def quotient(left, %Series{dtype: :integer} = right) when is_integer(left),
    do: apply_series_list(:quotient, [left, right])

  @doc """
  Computes the remainder of an element-wise integer division.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtype

    * `:integer`

  Returns `nil` if there is a zero in the right-hand side.

  ## Examples

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [0, 1, 0]
      >

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 0] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, s2)
      #Explorer.Series<
        Polars[3]
        integer [0, 1, nil]
      >

      iex> s1 = [10, 11, 9] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, 3)
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 0]
      >

  """
  @doc type: :element_wise
  @spec remainder(left :: Series.t(), right :: Series.t() | integer()) :: Series.t()
  def remainder(%Series{dtype: :integer} = left, %Series{dtype: :integer} = right),
    do: apply_series_list(:remainder, [left, right])

  def remainder(%Series{dtype: :integer} = left, right) when is_integer(right),
    do: apply_series_list(:remainder, [left, right])

  def remainder(left, %Series{dtype: :integer} = right) when is_integer(left),
    do: apply_series_list(:remainder, [left, right])

  @doc """
  Computes the the sine of a number (in radians).
  The resultant series is going to be of dtype `:float`, with values between 1 and -1.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> pi = :math.pi()
      iex> s = [-pi * 3/2, -pi, -pi / 2, -pi / 4, 0, pi / 4, pi / 2, pi, pi * 3/2] |> Explorer.Series.from_list()
      iex> Explorer.Series.sin(s)
      #Explorer.Series<
        Polars[9]
        float [1.0, -1.2246467991473532e-16, -1.0, -0.7071067811865475, 0.0, 0.7071067811865475, 1.0, 1.2246467991473532e-16, -1.0]
      >
  """
  @doc type: :float_wise
  @spec sin(series :: Series.t()) :: Series.t()
  def sin(%Series{dtype: :float} = series),
    do: apply_series(series, :sin)

  def sin(%Series{dtype: dtype}),
    do: dtype_error("sin/1", dtype, [:float])

  @doc """
  Computes the the cosine of a number (in radians).
  The resultant series is going to be of dtype `:float`, with values between 1 and -1.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> pi = :math.pi()
      iex> s = [-pi * 3/2, -pi, -pi / 2, -pi / 4, 0, pi / 4, pi / 2, pi, pi * 3/2] |> Explorer.Series.from_list()
      iex> Explorer.Series.cos(s)
      #Explorer.Series<
        Polars[9]
        float [-1.8369701987210297e-16, -1.0, 6.123233995736766e-17, 0.7071067811865476, 1.0, 0.7071067811865476, 6.123233995736766e-17, -1.0, -1.8369701987210297e-16]
      >
  """
  @doc type: :float_wise
  @spec cos(series :: Series.t()) :: Series.t()
  def cos(%Series{dtype: :float} = series),
    do: apply_series(series, :cos)

  def cos(%Series{dtype: dtype}),
    do: dtype_error("cos/1", dtype, [:float])

  @doc """
  Computes the tangent of a number (in radians).
  The resultant series is going to be of dtype `:float`.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> pi = :math.pi()
      iex> s = [-pi * 3/2, -pi, -pi / 2, -pi / 4, 0, pi / 4, pi / 2, pi, pi * 3/2] |> Explorer.Series.from_list()
      iex> Explorer.Series.tan(s)
      #Explorer.Series<
        Polars[9]
        float [-5443746451065123.0, 1.2246467991473532e-16, -1.633123935319537e16, -0.9999999999999999, 0.0, 0.9999999999999999, 1.633123935319537e16, -1.2246467991473532e-16, 5443746451065123.0]
      >
  """
  @doc type: :float_wise
  @spec tan(series :: Series.t()) :: Series.t()
  def tan(%Series{dtype: :float} = series),
    do: apply_series(series, :tan)

  def tan(%Series{dtype: dtype}),
    do: dtype_error("tan/1", dtype, [:float])

  @doc """
  Computes the the arcsine of a number.
  The resultant series is going to be of dtype `:float`, in radians, with values between -pi/2 and pi/2.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> s = [1.0, 0.0, -1.0, -0.7071067811865475, 0.7071067811865475] |> Explorer.Series.from_list()
      iex> Explorer.Series.asin(s)
      #Explorer.Series<
        Polars[5]
        float [1.5707963267948966, 0.0, -1.5707963267948966, -0.7853981633974482, 0.7853981633974482]
      >
  """
  @doc type: :float_wise
  @spec asin(series :: Series.t()) :: Series.t()
  def asin(%Series{dtype: :float} = series),
    do: apply_series(series, :asin)

  def asin(%Series{dtype: dtype}),
    do: dtype_error("asin/1", dtype, [:float])

  @doc """
  Computes the the arccosine of a number.
  The resultant series is going to be of dtype `:float`, in radians, with values between 0 and pi.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> s = [1.0, 0.0, -1.0, -0.7071067811865475, 0.7071067811865475] |> Explorer.Series.from_list()
      iex> Explorer.Series.acos(s)
      #Explorer.Series<
        Polars[5]
        float [0.0, 1.5707963267948966, 3.141592653589793, 2.356194490192345, 0.7853981633974484]
      >
  """
  @doc type: :float_wise
  @spec acos(series :: Series.t()) :: Series.t()
  def acos(%Series{dtype: :float} = series),
    do: apply_series(series, :acos)

  def acos(%Series{dtype: dtype}),
    do: dtype_error("acos/1", dtype, [:float])

  @doc """
  Computes the the arctangent of a number.
  The resultant series is going to be of dtype `:float`, in radians, with values between -pi/2 and pi/2.

  ## Supported dtype

    * `:float`

  ## Examples

      iex> s = [1.0, 0.0, -1.0, -0.7071067811865475, 0.7071067811865475] |> Explorer.Series.from_list()
      iex> Explorer.Series.atan(s)
      #Explorer.Series<
        Polars[5]
        float [0.7853981633974483, 0.0, -0.7853981633974483, -0.6154797086703873, 0.6154797086703873]
      >
  """
  @doc type: :float_wise
  @spec atan(series :: Series.t()) :: Series.t()
  def atan(%Series{dtype: :float} = series),
    do: apply_series(series, :atan)

  def atan(%Series{dtype: dtype}),
    do: dtype_error("atan/1", dtype, [:float])

  defp basic_numeric_operation(
         operation,
         %Series{dtype: left_dtype} = left,
         %Series{dtype: right_dtype} = right
       )
       when K.and(is_numeric_dtype(left_dtype), is_numeric_dtype(right_dtype)),
       do: apply_series_list(operation, [left, right])

  defp basic_numeric_operation(operation, %Series{} = left, %Series{} = right),
    do: dtype_mismatch_error("#{operation}/2", left, right)

  defp basic_numeric_operation(operation, %Series{dtype: dtype} = left, right)
       when K.and(is_numeric_dtype(dtype), is_numerical(right)),
       do: apply_series_list(operation, [left, right])

  defp basic_numeric_operation(operation, left, %Series{dtype: dtype} = right)
       when K.and(is_numeric_dtype(dtype), is_numerical(left)),
       do: apply_series_list(operation, [left, right])

  defp basic_numeric_operation(operation, _, %Series{dtype: dtype}),
    do: dtype_error("#{operation}/2", dtype, [:integer, :float])

  defp basic_numeric_operation(operation, %Series{dtype: dtype}, _),
    do: dtype_error("#{operation}/2", dtype, [:integer, :float])

  defp basic_numeric_operation(operation, left, right)
       when K.and(is_numerical(left), is_numerical(right)) do
    raise ArgumentError,
          "#{operation}/2 expect a series as one of its arguments, " <>
            "instead got two numbers: #{inspect(left)} and #{inspect(right)}"
  end

  # Comparisons

  @doc """
  Returns boolean mask of `left == right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.equal(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [true, true, false]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.equal(s, 1)
      #Explorer.Series<
        Polars[3]
        boolean [true, false, false]
      >

      iex> s = Explorer.Series.from_list([true, true, false])
      iex> Explorer.Series.equal(s, true)
      #Explorer.Series<
        Polars[3]
        boolean [true, true, false]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.equal(s, "a")
      #Explorer.Series<
        Polars[3]
        boolean [true, false, false]
      >

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.equal(s, ~D[1999-12-31])
      #Explorer.Series<
        Polars[2]
        boolean [false, true]
      >

      iex> s = Explorer.Series.from_list([~N[2022-01-01 00:00:00], ~N[2022-01-01 23:00:00]])
      iex> Explorer.Series.equal(s, ~N[2022-01-01 00:00:00])
      #Explorer.Series<
        Polars[2]
        boolean [true, false]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.equal(s, false)
      ** (ArgumentError) cannot invoke Explorer.Series.equal/2 with mismatched dtypes: :string and false
  """
  @doc type: :element_wise
  @spec equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def equal(left, right) do
    if K.or(valid_for_bool_mask_operation?(left, right), sides_comparable?(left, right)) do
      apply_series_list(:equal, [left, right])
    else
      dtype_mismatch_error("equal/2", left, right)
    end
  end

  @doc """
  Returns boolean mask of `left != right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.not_equal(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [false, false, true]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.not_equal(s, 1)
      #Explorer.Series<
        Polars[3]
        boolean [false, true, true]
      >

      iex> s = Explorer.Series.from_list([true, true, false])
      iex> Explorer.Series.not_equal(s, true)
      #Explorer.Series<
        Polars[3]
        boolean [false, false, true]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.not_equal(s, "a")
      #Explorer.Series<
        Polars[3]
        boolean [false, true, true]
      >

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.not_equal(s, ~D[1999-12-31])
      #Explorer.Series<
        Polars[2]
        boolean [true, false]
      >

      iex> s = Explorer.Series.from_list([~N[2022-01-01 00:00:00], ~N[2022-01-01 23:00:00]])
      iex> Explorer.Series.not_equal(s, ~N[2022-01-01 00:00:00])
      #Explorer.Series<
        Polars[2]
        boolean [false, true]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.not_equal(s, false)
      ** (ArgumentError) cannot invoke Explorer.Series.not_equal/2 with mismatched dtypes: :string and false
  """
  @doc type: :element_wise
  @spec not_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def not_equal(left, right) do
    if K.or(valid_for_bool_mask_operation?(left, right), sides_comparable?(left, right)) do
      apply_series_list(:not_equal, [left, right])
    else
      dtype_mismatch_error("not_equal/2", left, right)
    end
  end

  defp sides_comparable?(%Series{dtype: :string}, right) when is_binary(right), do: true
  defp sides_comparable?(%Series{dtype: :binary}, right) when is_binary(right), do: true
  defp sides_comparable?(%Series{dtype: :boolean}, right) when is_boolean(right), do: true
  defp sides_comparable?(left, %Series{dtype: :string}) when is_binary(left), do: true
  defp sides_comparable?(left, %Series{dtype: :binary}) when is_binary(left), do: true
  defp sides_comparable?(left, %Series{dtype: :boolean}) when is_boolean(left), do: true
  defp sides_comparable?(_, _), do: false

  @doc """
  Returns boolean mask of `left > right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [false, false, false]
      >
  """
  @doc type: :element_wise
  @spec greater(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      apply_series_list(:greater, [left, right])
    else
      dtypes = [:integer, :float, :date, :time, :datetime]
      dtype_mismatch_error("greater/2", left, right, dtypes)
    end
  end

  @doc """
  Returns boolean mask of `left >= right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater_equal(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [true, true, false]
      >
  """
  @doc type: :element_wise
  @spec greater_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater_equal(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      apply_series_list(:greater_equal, [left, right])
    else
      types = [:integer, :float, :date, :time, :datetime]
      dtype_mismatch_error("greater_equal/2", left, right, types)
    end
  end

  @doc """
  Returns boolean mask of `left < right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [false, false, true]
      >
  """
  @doc type: :element_wise
  @spec less(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      apply_series_list(:less, [left, right])
    else
      dtypes = [:integer, :float, :date, :time, :datetime]
      dtype_mismatch_error("less/2", left, right, dtypes)
    end
  end

  @doc """
  Returns boolean mask of `left <= right`, element-wise.

  At least one of the arguments must be a series. If both
  sizes are series, the series must have the same size or
  at last one of them must have size of 1.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:time`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less_equal(s1, s2)
      #Explorer.Series<
        Polars[3]
        boolean [true, true, true]
      >
  """
  @doc type: :element_wise
  @spec less_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less_equal(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      apply_series_list(:less_equal, [left, right])
    else
      types = [:integer, :float, :date, :time, :datetime]
      dtype_mismatch_error("less_equal/2", left, right, types)
    end
  end

  @doc """
  Checks if each element of the series in the left exists in the series in the right, returning a boolean mask.

  The series sizes do not have to match.

  ## Examples

      iex> left = Explorer.Series.from_list([1, 2, 3])
      iex> right = Explorer.Series.from_list([1, 2])
      iex> Series.in(left, right)
      #Explorer.Series<
        Polars[3]
        boolean [true, true, false]
      >

      iex> left = Explorer.Series.from_list([~D[1970-01-01], ~D[2000-01-01], ~D[2010-04-17]])
      iex> right = Explorer.Series.from_list([~D[1970-01-01], ~D[2010-04-17]])
      iex> Series.in(left, right)
      #Explorer.Series<
        Polars[3]
        boolean [true, false, true]
      >
  """
  @doc type: :element_wise
  def (%Series{} = left) in (%Series{} = right) do
    if valid_for_bool_mask_operation?(left, right) do
      apply_series_list(:binary_in, [left, right])
    else
      dtype_mismatch_error("in/2", left, right)
    end
  end

  def (%Series{} = left) in right when is_list(right),
    do: left in Explorer.Series.from_list(right)

  defp valid_for_bool_mask_operation?(%Series{dtype: dtype}, %Series{dtype: dtype}),
    do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: left_dtype}, %Series{dtype: right_dtype})
       when K.and(is_numeric_dtype(left_dtype), is_numeric_dtype(right_dtype)),
       do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: dtype}, right)
       when K.and(is_numeric_dtype(dtype), is_numerical(right)),
       do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: :date}, %Date{}), do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: :datetime}, %NaiveDateTime{}), do: true

  defp valid_for_bool_mask_operation?(left, %Series{dtype: dtype})
       when K.and(is_numeric_dtype(dtype), is_numerical(left)),
       do: true

  defp valid_for_bool_mask_operation?(%Date{}, %Series{dtype: :date}), do: true

  defp valid_for_bool_mask_operation?(%NaiveDateTime{}, %Series{dtype: :datetime}), do: true

  defp valid_for_bool_mask_operation?(_, _), do: false

  @doc """
  Returns a boolean mask of `left and right`, element-wise.

  Both sizes must be series, the series must have the same
  size or at last one of them must have size of 1.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.greater(s1, 1)
      iex> mask2 = Explorer.Series.less(s1, 3)
      iex> Explorer.Series.and(mask1, mask2)
      #Explorer.Series<
        Polars[3]
        boolean [false, true, false]
      >

  """
  @doc type: :element_wise
  def (%Series{dtype: :boolean} = left) and (%Series{dtype: :boolean} = right),
    do: apply_series_list(:binary_and, [left, right])

  def (%Series{} = left) and (%Series{} = right),
    do: dtype_mismatch_error("and/2", left, right, [:boolean])

  @doc """
  Returns a boolean mask of `left or right`, element-wise.

  Both sizes must be series, the series must have the same
  size or at last one of them must have size of 1.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.less(s1, 2)
      iex> mask2 = Explorer.Series.greater(s1, 2)
      iex> Explorer.Series.or(mask1, mask2)
      #Explorer.Series<
        Polars[3]
        boolean [true, false, true]
      >

  """
  @doc type: :element_wise
  def (%Series{dtype: :boolean} = left) or (%Series{dtype: :boolean} = right),
    do: apply_series_list(:binary_or, [left, right])

  def (%Series{} = left) or (%Series{} = right),
    do: dtype_mismatch_error("or/2", left, right, [:boolean])

  @doc """
  Checks equality between two entire series.

  ## Examples

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "b"])
      iex> Explorer.Series.all_equal(s1, s2)
      true

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "c"])
      iex> Explorer.Series.all_equal(s1, s2)
      false

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list([1, 2])
      iex> Explorer.Series.all_equal(s1, s2)
      false
  """
  @doc type: :element_wise
  def all_equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right),
    do: apply_series_list(:all_equal, [left, right])

  def all_equal(%Series{dtype: left_dtype}, %Series{dtype: right_dtype})
      when left_dtype !=
             right_dtype,
      do: false

  @doc """
  Negate the elements of a boolean series.

  ## Examples

      iex> s1 = Explorer.Series.from_list([true, false, false])
      iex> Explorer.Series.not(s1)
      #Explorer.Series<
        Polars[3]
        boolean [false, true, true]
      >

  """
  @doc type: :element_wise
  def not (%Series{dtype: :boolean} = series), do: apply_series(series, :unary_not, [])
  def not %Series{dtype: dtype}, do: dtype_error("not/1", dtype, [:boolean])

  # Sort

  @doc """
  Sorts the series.

  Sorting is stable by default.

  ## Options

    * `:direction` - `:asc` or `:desc`, meaning "ascending" or "descending", respectively.
      By default it sorts in acending order.

    * `:nils` - `:first` or `:last`. By default it is `:last` if direction is `:asc`, and
      `:first` otherwise.

  ## Examples

      iex> s = Explorer.Series.from_list([9, 3, 7, 1])
      iex> Explorer.Series.sort(s)
      #Explorer.Series<
        Polars[4]
        integer [1, 3, 7, 9]
      >

      iex> s = Explorer.Series.from_list([9, 3, 7, 1])
      iex> Explorer.Series.sort(s, direction: :desc)
      #Explorer.Series<
        Polars[4]
        integer [9, 7, 3, 1]
      >

  """
  @doc type: :shape
  def sort(series, opts \\ []) do
    opts = Keyword.validate!(opts, [:nils, direction: :asc])
    descending? = opts[:direction] == :desc
    nils_last? = if nils = opts[:nils], do: nils == :last, else: K.not(descending?)

    apply_series(series, :sort, [descending?, nils_last?])
  end

  @doc """
  Returns the indices that would sort the series.

  ## Options

    * `:direction` - `:asc` or `:desc`, meaning "ascending" or "descending", respectively.
      By default it sorts in acending order.

    * `:nils` - `:first` or `:last`. By default it is `:last` if direction is `:asc`, and
      `:first` otherwise.

  ## Examples

      iex> s = Explorer.Series.from_list([9, 3, 7, 1])
      iex> Explorer.Series.argsort(s)
      #Explorer.Series<
        Polars[4]
        integer [3, 1, 2, 0]
      >

      iex> s = Explorer.Series.from_list([9, 3, 7, 1])
      iex> Explorer.Series.argsort(s, direction: :desc)
      #Explorer.Series<
        Polars[4]
        integer [0, 2, 1, 3]
      >

  """
  @doc type: :shape
  def argsort(series, opts \\ []) do
    opts = Keyword.validate!(opts, [:nils, direction: :asc])
    descending? = opts[:direction] == :desc
    nils_last? = if nils = opts[:nils], do: nils == :last, else: K.not(descending?)

    apply_series(series, :argsort, [descending?, nils_last?])
  end

  @doc """
  Reverses the series order.

  ## Example

      iex> s = [1, 2, 3] |> Explorer.Series.from_list()
      iex> Explorer.Series.reverse(s)
      #Explorer.Series<
        Polars[3]
        integer [3, 2, 1]
      >
  """
  @doc type: :shape
  def reverse(series), do: apply_series(series, :reverse)

  # Distinct

  @doc """
  Returns the unique values of the series.

  ## Examples

      iex> s = [1, 1, 2, 2, 3, 3] |> Explorer.Series.from_list()
      iex> Explorer.Series.distinct(s)
      #Explorer.Series<
        Polars[3]
        integer [1, 2, 3]
      >
  """
  @doc type: :shape
  def distinct(series), do: apply_series(series, :distinct)

  @doc """
  Returns the unique values of the series, but does not maintain order.

  Faster than `distinct/1`.

  ## Examples

      iex> s = [1, 1, 2, 2, 3, 3] |> Explorer.Series.from_list()
      iex> Explorer.Series.unordered_distinct(s)
  """
  @doc type: :shape
  def unordered_distinct(series), do: apply_series(series, :unordered_distinct)

  @doc """
  Returns the number of unique values in the series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "a", "b"])
      iex> Explorer.Series.n_distinct(s)
      2
  """
  @doc type: :aggregation
  def n_distinct(series), do: apply_series(series, :n_distinct)

  @doc """
  Creates a new dataframe with unique values and the frequencies of each.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "a", "b", "c", "c", "c"])
      iex> Explorer.Series.frequencies(s)
      #Explorer.DataFrame<
        Polars[3 x 2]
        values string ["c", "a", "b"]
        counts integer [3, 2, 1]
      >
  """
  @doc type: :aggregation
  def frequencies(series), do: apply_series(series, :frequencies)

  @doc """
  Counts the number of elements in a series.

  In the context of lazy series and `Explorer.Query`,
  `count/1` counts the elements inside the same group.
  If no group is in use, then count is going to return
  the size of the series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.count(s)
      3

  """
  @doc type: :aggregation
  def count(series), do: apply_series(series, :count)

  @doc """
  Counts the number of null elements in a series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", nil, "c", nil, nil])
      iex> Explorer.Series.nil_count(s)
      3

  """
  @doc type: :aggregation
  def nil_count(series), do: apply_series(series, :nil_count)

  # Window

  @doc """
  Calculate the rolling sum, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_sum(s, 4)
      #Explorer.Series<
        Polars[10]
        integer [1, 3, 6, 10, 14, 18, 22, 26, 30, 34]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_sum(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        Polars[10]
        float [1.0, 5.0, 8.0, 11.0, 14.0, 17.0, 20.0, 23.0, 26.0, 29.0]
      >
  """
  @doc type: :window
  def window_sum(series, window_size, opts \\ []),
    do: apply_series(series, :window_sum, [window_size | window_args(opts)])

  @doc """
  Calculate the rolling mean, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_mean(s, 4)
      #Explorer.Series<
        Polars[10]
        float [1.0, 1.5, 2.0, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_mean(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        Polars[10]
        float [1.0, 2.5, 4.0, 5.5, 7.0, 8.5, 10.0, 11.5, 13.0, 14.5]
      >
  """
  @doc type: :window
  def window_mean(series, window_size, opts \\ []),
    do: apply_series(series, :window_mean, [window_size | window_args(opts)])

  @doc """
  Calculate the rolling min, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_min(s, 4)
      #Explorer.Series<
        Polars[10]
        integer [1, 1, 1, 1, 2, 3, 4, 5, 6, 7]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_min(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        Polars[10]
        float [1.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]
      >
  """
  @doc type: :window
  def window_min(series, window_size, opts \\ []),
    do: apply_series(series, :window_min, [window_size | window_args(opts)])

  @doc """
  Calculate the rolling max, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_max(s, 4)
      #Explorer.Series<
        Polars[10]
        integer [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_max(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        Polars[10]
        float [1.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
      >
  """
  @doc type: :window
  def window_max(series, window_size, opts \\ []),
    do: apply_series(series, :window_max, [window_size | window_args(opts)])

  defp window_args(opts) do
    opts = Keyword.validate!(opts, weights: nil, min_periods: 1, center: false)
    [opts[:weights], opts[:min_periods], opts[:center]]
  end

  @doc """
  Calculate the exponentially weighted moving average, given smoothing factor alpha.

  ## Options

    * `:alpha` - Optional smoothing factor which specifies the imporance given
      to most recent observations. It is a value such that, 0 < alpha <= 1. Defaults to 0.5.

    * `:adjust` - If set to true, it corrects the bias introduced by smoothing process.
      Defaults to `true`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. Defaults to `1`.

    * `:ignore_nils` - If set to true, it ignore nulls in the calculation. Defaults to `true`.

  ## Examples

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.ewm_mean(s)
      #Explorer.Series<
        Polars[5]
        float [1.0, 1.6666666666666667, 2.4285714285714284, 3.2666666666666666, 4.161290322580645]
      >

      iex> s = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.ewm_mean(s, alpha: 0.1)
      #Explorer.Series<
        Polars[5]
        float [1.0, 1.5263157894736843, 2.070110701107011, 2.6312881651642916, 3.2097140484969833]
      >
  """
  @doc type: :window
  def ewm_mean(series, opts \\ []) do
    opts = Keyword.validate!(opts, alpha: 0.5, adjust: true, min_periods: 1, ignore_nils: true)

    apply_series(series, :ewm_mean, [
      opts[:alpha],
      opts[:adjust],
      opts[:min_periods],
      opts[:ignore_nils]
    ])
  end

  # Missing values

  @doc """
  Fill missing values with the given strategy. If a scalar value is provided instead of a strategy
  atom, `nil` will be replaced with that value. It must be of the same `dtype` as the series.

  ## Strategies

    * `:forward` - replace nil with the previous value
    * `:backward` - replace nil with the next value
    * `:max` - replace nil with the series maximum
    * `:min` - replace nil with the series minimum
    * `:mean` - replace nil with the series mean
    * `:nan` (float only) - replace nil with `NaN`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :forward)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 2, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :backward)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :max)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :min)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 1, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :mean)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 2, 4]
      >

  Values that belong to the series itself can also be added as missing:

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, 3)
      #Explorer.Series<
        Polars[4]
        integer [1, 2, 3, 4]
      >

      iex> s = Explorer.Series.from_list(["a", "b", nil, "d"])
      iex> Explorer.Series.fill_missing(s, "c")
      #Explorer.Series<
        Polars[4]
        string ["a", "b", "c", "d"]
      >

  Mismatched types will raise:

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, "foo")
      ** (ArgumentError) cannot invoke Explorer.Series.fill_missing/2 with mismatched dtypes: :integer and "foo"

  Floats in particular accept missing values to be set to NaN, Inf, and -Inf:

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 4.0])
      iex> Explorer.Series.fill_missing(s, :nan)
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, NaN, 4.0]
      >

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 4.0])
      iex> Explorer.Series.fill_missing(s, :infinity)
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, Inf, 4.0]
      >

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 4.0])
      iex> Explorer.Series.fill_missing(s, :neg_infinity)
      #Explorer.Series<
        Polars[4]
        float [1.0, 2.0, -Inf, 4.0]
      >

  """
  @doc type: :window
  @spec fill_missing(
          Series.t(),
          :forward
          | :backward
          | :max
          | :min
          | :mean
          | :nan
          | :infinity
          | :neg_infinity
          | Explorer.Backend.Series.valid_types()
        ) :: Series.t()
  def fill_missing(%Series{} = series, value)
      when K.in(value, [:nan, :infinity, :neg_infinity]) do
    if series.dtype != :float do
      raise ArgumentError,
            "fill_missing with :#{value} values require a :float series, got #{inspect(series.dtype)}"
    end

    apply_series(series, :fill_missing_with_value, [value])
  end

  def fill_missing(%Series{} = series, strategy)
      when K.in(strategy, [:forward, :backward, :min, :max, :mean]),
      do: apply_series(series, :fill_missing_with_strategy, [strategy])

  def fill_missing(%Series{} = series, value) do
    if K.or(
         valid_for_bool_mask_operation?(series, value),
         sides_comparable?(series, value)
       ) do
      apply_series(series, :fill_missing_with_value, [value])
    else
      dtype_mismatch_error("fill_missing/2", series, value)
    end
  end

  @doc """
  Returns a mask of nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.is_nil(s)
      #Explorer.Series<
        Polars[4]
        boolean [false, false, true, false]
      >
  """
  @doc type: :element_wise
  @spec is_nil(Series.t()) :: Series.t()
  def is_nil(series), do: apply_series(series, :is_nil)

  @doc """
  Returns a mask of not nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.is_not_nil(s)
      #Explorer.Series<
        Polars[4]
        boolean [true, true, false, true]
      >
  """
  @doc type: :element_wise
  @spec is_not_nil(Series.t()) :: Series.t()
  def is_not_nil(series), do: apply_series(series, :is_not_nil)

  # Strings

  @doc """
  Detects whether a string contains a substring.

  ## Examples

      iex> s = Explorer.Series.from_list(["abc", "def", "bcd"])
      iex> Explorer.Series.contains(s, "bc")
      #Explorer.Series<
        Polars[3]
        boolean [true, false, true]
      >
  """
  @doc type: :string_wise
  @spec contains(Series.t(), String.t() | Regex.t()) :: Series.t()
  def contains(%Series{dtype: :string} = series, pattern)
      when K.or(K.is_binary(pattern), K.is_struct(pattern, Regex)),
      do: apply_series(series, :contains, [pattern])

  def contains(%Series{dtype: dtype}, _), do: dtype_error("contains/2", dtype, [:string])

  @doc """
  Converts all characters to uppercase.

  ## Examples

      iex> s = Explorer.Series.from_list(["abc", "def", "bcd"])
      iex> Explorer.Series.upcase(s)
      #Explorer.Series<
        Polars[3]
        string ["ABC", "DEF", "BCD"]
      >
  """
  @doc type: :string_wise
  @spec upcase(Series.t()) :: Series.t()
  def upcase(%Series{dtype: :string} = series),
    do: apply_series(series, :upcase)

  def upcase(%Series{dtype: dtype}), do: dtype_error("upcase/1", dtype, [:string])

  @doc """
  Converts all characters to lowercase.

  ## Examples

      iex> s = Explorer.Series.from_list(["ABC", "DEF", "BCD"])
      iex> Explorer.Series.downcase(s)
      #Explorer.Series<
        Polars[3]
        string ["abc", "def", "bcd"]
      >
  """
  @doc type: :string_wise
  @spec downcase(Series.t()) :: Series.t()
  def downcase(%Series{dtype: :string} = series),
    do: apply_series(series, :downcase)

  def downcase(%Series{dtype: dtype}), do: dtype_error("downcase/1", dtype, [:string])

  @doc """
  Returns a string where all leading and trailing Unicode whitespaces have been removed.

  ## Examples

      iex> s = Explorer.Series.from_list(["  abc", "def  ", "  bcd"])
      iex> Explorer.Series.trim(s)
      #Explorer.Series<
        Polars[3]
        string ["abc", "def", "bcd"]
      >
  """
  @doc type: :string_wise
  @spec trim(Series.t()) :: Series.t()
  def trim(%Series{dtype: :string} = series),
    do: apply_series(series, :trim)

  def trim(%Series{dtype: dtype}), do: dtype_error("trim/1", dtype, [:string])

  @doc """
  Returns a string where all leading Unicode whitespaces have been removed.

  ## Examples

      iex> s = Explorer.Series.from_list(["  abc", "def  ", "  bcd"])
      iex> Explorer.Series.trim_leading(s)
      #Explorer.Series<
        Polars[3]
        string ["abc", "def  ", "bcd"]
      >
  """
  @doc type: :string_wise
  @spec trim_leading(Series.t()) :: Series.t()
  def trim_leading(%Series{dtype: :string} = series),
    do: apply_series(series, :trim_leading)

  def trim_leading(%Series{dtype: dtype}), do: dtype_error("trim_leading/1", dtype, [:string])

  @doc """
  Returns a string where all trailing Unicode whitespaces have been removed.

  ## Examples

      iex> s = Explorer.Series.from_list(["  abc", "def  ", "  bcd"])
      iex> Explorer.Series.trim_trailing(s)
      #Explorer.Series<
        Polars[3]
        string ["  abc", "def", "  bcd"]
      >
  """
  @doc type: :string_wise
  @spec trim_trailing(Series.t()) :: Series.t()
  def trim_trailing(%Series{dtype: :string} = series),
    do: apply_series(series, :trim_trailing)

  def trim_trailing(%Series{dtype: dtype}), do: dtype_error("trim_trailing/1", dtype, [:string])

  # Float

  @doc """
  Round floating point series to given decimal places.

  ## Examples

      iex> s = Explorer.Series.from_list([1.124993, 2.555321, 3.995001])
      iex> Explorer.Series.round(s, 2)
      #Explorer.Series<
        Polars[3]
        float [1.12, 2.56, 4.0]
      >
  """
  @doc type: :float_wise
  @spec round(Series.t(), non_neg_integer()) :: Series.t()
  def round(%Series{dtype: :float} = series, decimals)
      when K.and(is_integer(decimals), decimals >= 0),
      do: apply_series(series, :round, [decimals])

  def round(%Series{dtype: :float}, _),
    do: raise(ArgumentError, "second argument to round/2 must be a non-negative integer")

  def round(%Series{dtype: dtype}, _), do: dtype_error("round/2", dtype, [:float])

  @doc """
  Floor floating point series to lowest integers smaller or equal to the float value.

  ## Examples

      iex> s = Explorer.Series.from_list([1.124993, 2.555321, 3.995001])
      iex> Explorer.Series.floor(s)
      #Explorer.Series<
        Polars[3]
        float [1.0, 2.0, 3.0]
      >
  """
  @doc type: :float_wise
  @spec floor(Series.t()) :: Series.t()
  def floor(%Series{dtype: :float} = series), do: apply_series(series, :floor)
  def floor(%Series{dtype: dtype}), do: dtype_error("floor/1", dtype, [:float])

  @doc """
  Ceil floating point series to highest integers smaller or equal to the float value.

  ## Examples

      iex> s = Explorer.Series.from_list([1.124993, 2.555321, 3.995001])
      iex> Explorer.Series.ceil(s)
      #Explorer.Series<
        Polars[3]
        float [2.0, 3.0, 4.0]
      >
  """
  @doc type: :float_wise
  @spec ceil(Series.t()) :: Series.t()
  def ceil(%Series{dtype: :float} = series), do: apply_series(series, :ceil)
  def ceil(%Series{dtype: dtype}), do: dtype_error("ceil/1", dtype, [:float])

  @doc """
  Returns a mask of finite values.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 0, nil])
      iex> s2 = Explorer.Series.from_list([0, 2, 0, nil])
      iex> s3 = Explorer.Series.divide(s1, s2)
      iex> Explorer.Series.is_finite(s3)
      #Explorer.Series<
        Polars[4]
        boolean [false, true, false, nil]
      >
  """
  @doc type: :float_wise
  @spec is_finite(Series.t()) :: Series.t()
  def is_finite(%Series{dtype: :float} = series),
    do: apply_series(series, :is_finite)

  def is_finite(%Series{dtype: dtype}), do: dtype_error("is_finite/1", dtype, [:float])

  @doc """
  Returns a mask of infinite values.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, -1, 2, 0, nil])
      iex> s2 = Explorer.Series.from_list([0, 0, 2, 0, nil])
      iex> s3 = Explorer.Series.divide(s1, s2)
      iex> Explorer.Series.is_infinite(s3)
      #Explorer.Series<
        Polars[5]
        boolean [true, true, false, false, nil]
      >
  """
  @doc type: :float_wise
  @spec is_infinite(Series.t()) :: Series.t()
  def is_infinite(%Series{dtype: :float} = series),
    do: apply_series(series, :is_infinite)

  def is_infinite(%Series{dtype: dtype}),
    do: dtype_error("is_infinite/1", dtype, [:float])

  @doc """
  Returns a mask of infinite values.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 0, nil])
      iex> s2 = Explorer.Series.from_list([0, 2, 0, nil])
      iex> s3 = Explorer.Series.divide(s1, s2)
      iex> Explorer.Series.is_nan(s3)
      #Explorer.Series<
        Polars[4]
        boolean [false, false, true, nil]
      >
  """
  @doc type: :float_wise
  @spec is_nan(Series.t()) :: Series.t()
  def is_nan(%Series{dtype: :float} = series),
    do: apply_series(series, :is_nan)

  def is_nan(%Series{dtype: dtype}), do: dtype_error("is_nan/1", dtype, [:float])

  # Date / DateTime

  @doc """
  Returns a day-of-week number starting from Monday = 1. (ISO 8601 weekday number)

  ## Examples

      iex> s = Explorer.Series.from_list([~D[2023-01-15], ~D[2023-01-16], ~D[2023-01-20], nil])
      iex> Explorer.Series.day_of_week(s)
      #Explorer.Series<
        Polars[4]
        integer [7, 1, 5, nil]
      >

  It can also be called on a datetime series.

      iex> s = Explorer.Series.from_list([~N[2023-01-15 00:00:00], ~N[2023-01-16 23:59:59.999999], ~N[2023-01-20 12:00:00], nil])
      iex> Explorer.Series.day_of_week(s)
      #Explorer.Series<
        Polars[4]
        integer [7, 1, 5, nil]
      >
  """

  @doc type: :datetime_wise
  @spec day_of_week(Series.t()) :: Series.t()
  def day_of_week(%Series{dtype: dtype} = series) when K.in(dtype, [:date, :datetime]),
    do: apply_series_list(:day_of_week, [series])

  def day_of_week(%Series{dtype: dtype}),
    do: dtype_error("day_of_week/1", dtype, [:date, :datetime])

  @doc """
  Returns date component from the datetime series

  ## Examples

      iex> s = Explorer.Series.from_list([~N[2023-01-15 00:00:00.000000], ~N[2023-01-16 23:59:59.999999], ~N[2023-01-20 12:00:00.000000], nil])
      iex> Explorer.Series.to_date(s)
      #Explorer.Series<
        Polars[4]
        date [2023-01-15, 2023-01-16, 2023-01-20, nil]
      >
  """

  @doc type: :datetime_wise
  @spec to_date(Series.t()) :: Series.t()
  def to_date(%Series{dtype: :datetime} = series),
    do: apply_series_list(:to_date, [series])

  def to_date(%Series{dtype: dtype}),
    do: dtype_error("to_date/1", dtype, [:datetime])

  @doc """
  Returns time component from the datetime series

  ## Examples

      iex> s = Explorer.Series.from_list([~N[2023-01-15 00:00:00.000000], ~N[2023-01-16 23:59:59.999999], ~N[2023-01-20 12:00:00.000000], nil])
      iex> Explorer.Series.to_time(s)
      #Explorer.Series<
        Polars[4]
        time [00:00:00.000000, 23:59:59.999999, 12:00:00.000000, nil]
      >
  """

  @doc type: :datetime_wise
  @spec to_time(Series.t()) :: Series.t()
  def to_time(%Series{dtype: :datetime} = series),
    do: apply_series_list(:to_time, [series])

  def to_time(%Series{dtype: dtype}),
    do: dtype_error("to_time/1", dtype, [:datetime])

  # Escape hatch

  @doc """
  Returns an `Explorer.Series` where each element is the result of invoking `fun` on each
  corresponding element of `series`.

  This is an expensive operation meant to enable the use of arbitrary Elixir functions against
  any backend. The implementation will vary by backend but in most (all?) cases will require
  converting to an `Elixir.List`, applying `Enum.map/2`, and then converting back to an
  `Explorer.Series`.

  ## Examples

      iex> s = Explorer.Series.from_list(["this ", " is", "great   "])
      iex> Explorer.Series.transform(s, &String.trim/1)
      #Explorer.Series<
        Polars[3]
        string ["this", "is", "great"]
      >

      iex> s = Explorer.Series.from_list(["this", "is", "great"])
      iex> Explorer.Series.transform(s, &String.length/1)
      #Explorer.Series<
        Polars[3]
        integer [4, 2, 5]
      >
  """
  @doc type: :element_wise
  def transform(series, fun) do
    apply_series(series, :transform, [fun])
  end

  # Helpers

  defp apply_series(series, fun, args \\ []) do
    if impl = impl!([series]) do
      apply(impl, fun, [series | args])
    else
      raise ArgumentError,
            "expected a series as argument for #{fun}, got: #{inspect(series)}" <>
              maybe_hint([series])
    end
  end

  defp apply_series_list(fun, series_or_scalars) when is_list(series_or_scalars) do
    impl = impl!(series_or_scalars)
    apply(impl, fun, series_or_scalars)
  end

  defp impl!([_ | _] = series_or_scalars) do
    Enum.reduce(series_or_scalars, nil, fn
      %{data: %struct{}}, nil -> struct
      %{data: %struct{}}, impl -> pick_series_impl(impl, struct)
      _scalar, impl -> impl
    end)
  end

  defp pick_series_impl(struct, struct), do: struct
  defp pick_series_impl(Explorer.Backend.LazySeries, _), do: Explorer.Backend.LazySeries
  defp pick_series_impl(_, Explorer.Backend.LazySeries), do: Explorer.Backend.LazySeries

  defp pick_series_impl(struct1, struct2) do
    raise "cannot invoke Explorer function because it relies on two incompatible series: " <>
            "#{inspect(struct1)} and #{inspect(struct2)}"
  end

  defp backend_from_options!(opts) do
    backend = Explorer.Shared.backend_from_options!(opts) || Explorer.Backend.get()

    :"#{backend}.Series"
  end

  defp dtype_error(function, dtype, valid_dtypes) do
    raise(
      ArgumentError,
      "Explorer.Series.#{function} not implemented for dtype #{inspect(dtype)}. " <>
        "Valid dtypes are #{inspect(valid_dtypes)}"
    )
  end

  defp dtype_mismatch_error(function, left, right, valid) do
    left_series? = match?(%Series{}, left)
    right_series? = match?(%Series{}, right)

    cond do
      Kernel.and(left_series?, Kernel.not(Enum.member?(valid, left.dtype))) ->
        dtype_error(function, left.dtype, valid)

      Kernel.and(right_series?, Kernel.not(Enum.member?(valid, right.dtype))) ->
        dtype_error(function, right.dtype, valid)

      Kernel.or(left_series?, right_series?) ->
        dtype_mismatch_error(function, left, right)

      true ->
        raise(
          ArgumentError,
          "expecting series for one of the sides, but got: " <>
            "#{dtype_or_inspect(left)} (lhs) and #{dtype_or_inspect(right)} (rhs)" <>
            maybe_hint([left, right])
        )
    end
  end

  defp dtype_mismatch_error(function, left, right) do
    raise(
      ArgumentError,
      "cannot invoke Explorer.Series.#{function} with mismatched dtypes: #{dtype_or_inspect(left)} and " <>
        "#{dtype_or_inspect(right)}" <> maybe_hint([left, right])
    )
  end

  defp dtype_or_inspect(%Series{dtype: dtype}), do: inspect(dtype)
  defp dtype_or_inspect(value), do: inspect(value)

  defp maybe_hint(values) do
    atom = Enum.find(values, &is_atom(&1))

    if Kernel.and(atom != nil, String.starts_with?(Atom.to_string(atom), "Elixir.")) do
      "\n\nHINT: we have noticed that one of the values is the atom #{inspect(atom)}. " <>
        "If you are inside Explorer.Query and you want to access a column starting in uppercase, " <>
        "you must write instead: col(\"#{inspect(atom)}\")"
    else
      ""
    end
  end

  defp check_dtypes_for_coalesce!(%Series{} = s1, %Series{} = s2) do
    case {s1.dtype, s2.dtype} do
      {dtype, dtype} -> :ok
      {:integer, :float} -> :ok
      {:float, :integer} -> :ok
      {left, right} -> dtype_mismatch_error("coalesce/2", left, right)
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(df, opts) do
      force_unfit(
        concat([
          color("#Explorer.Series<", :map, opts),
          nest(
            concat([line(), Shared.apply_impl(df, :inspect, [opts])]),
            2
          ),
          line(),
          color(">", :map, opts)
        ])
      )
    end
  end
end

defmodule Explorer.Series.Iterator do
  @moduledoc false
  defstruct [:series, :size, :impl]

  def new(%{data: %impl{}} = series) do
    %__MODULE__{series: series, size: impl.size(series), impl: impl}
  end

  defimpl Enumerable do
    def count(iterator), do: {:ok, iterator.size}

    def member?(_iterator, _value), do: {:error, __MODULE__}

    def slice(%{size: size, series: series, impl: impl}) do
      {:ok, size,
       fn start, size ->
         series
         |> impl.slice(start, size)
         |> impl.to_list()
       end}
    end

    def reduce(%{series: series, size: size, impl: impl}, acc, fun) do
      reduce(series, impl, size, 0, acc, fun)
    end

    defp reduce(_series, _impl, _size, _offset, {:halt, acc}, _fun), do: {:halted, acc}

    defp reduce(series, impl, size, offset, {:suspend, acc}, fun) do
      {:suspended, acc, &reduce(series, impl, size, offset, &1, fun)}
    end

    defp reduce(_series, _impl, size, size, {:cont, acc}, _fun), do: {:done, acc}

    defp reduce(series, impl, size, offset, {:cont, acc}, fun) do
      value = impl.at(series, offset)
      reduce(series, impl, size, offset + 1, fun.(value, acc), fun)
    end
  end
end
