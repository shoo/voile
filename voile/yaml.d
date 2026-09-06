/*******************************************************************************
 * YAML パース・ビルド・シリアライズ・デシリアライズライブラリ
 * 
 * 以下の機能を提供する:
 * - YAMLテキストのパース (`parseYaml`)
 * - YAML値ツリーの構築 (`makeYaml` 等)
 * - YAML値ツリーからの文字列生成 (`serializeToYamlString` 等)
 * - D型 ↔ YAML値ツリーの相互変換 (`serializeToYaml` / `deserializeFromYaml`)
 * - コメント・数値表現・記述スタイル（block/flow・ケツカンマ等）の維持
 * 
 * 非対応機能:
 * - 複数ドキュメントストリーム (`---`/`...`/ディレクティブ)
 * - 非スカラーキー (`? complex-key`)
 * - マージキー (`<<: *anchor`) — 将来拡張予定
 * - セクサジェシマル (60進数)
 */
module voile.yaml;

import std.algorithm  : map, filter, among, startsWith, endsWith, canFind, joiner, move;
import std.array      : Appender, appender, join, split;
import std.conv       : to, text, parse, ConvException;
import std.conv;
import std.ascii      : isDigit, isHexDigit, isOctalDigit;
import std.exception  : enforce, collectException;
import std.format     : format, formattedWrite, sformat;
import std.meta       : AliasSeq, staticMap, Filter, allSatisfy, staticIndexOf;
import std.range      : isOutputRange, ElementType, repeat, put;
import std.string     : outdent, splitLines, strip, stripRight, stripLeft, indexOf, chompPrefix;
import std.traits     : isIntegral, isFloatingPoint, isSomeString, isArray,
                        isAssociativeArray, isBoolean, Unqual, FieldNameTuple,
                        KeyType, ValueType, isInstanceOf, hasMember,
                        isSigned, isUnsigned, isAggregateType, isDynamicArray,
                        hasElaborateAssign, hasElaborateCopyConstructor,
                        hasElaborateMove, hasElaborateDestructor, hasNested,
                        ReturnType, TemplateArgsOf, lvalueOf, hasUDA, getUDAs,
                        isPointer;
import std.typecons   : Nullable, nullable, Tuple, isTuple;
import std.sumtype    : SumType, match, isSumType;
import std.utf        : encode;

import voile.attr;
private alias attr = voile.attr;

// ============================================================================
// MARK: Attributes
// ============================================================================

// voile.attr の汎用UDAを再エクスポート（フォーマット非依存のためそのまま使用）
alias ignore      = voile.attr.ignore;
alias ignoreIf    = voile.attr.ignoreIf;
alias name        = voile.attr.name;
alias value       = voile.attr.value;
alias convertFrom = voile.attr.convertFrom;
alias convertTo   = voile.attr.convertTo;

// --------------------------------------------------------------------------
// kind (SumTypeシリアライズ用タグ属性)
// --------------------------------------------------------------------------

private struct Kind
{
	string key;
	string value;
}

/*******************************************************************************
 * SumType のシリアライズに使うタグ属性
 * 
 * SumType の各バリアント型に付与することで、シリアライズ時に型を識別するための
 * キー・値ペアをYAMLマッピングに追加する。
 * Params:
 *     name  = タグキー名
 *     value = タグ値文字列
 */
auto kind(string name, string value) @safe
{
	return Kind(name, value);
}

/// ditto
auto kind(string value) @safe
{
	return Kind("$type", value);
}

/// ditto
auto kind(string value)() @safe
{
	return Kind("$type", value);
}
///
@safe unittest
{
	import std.sumtype : SumType;
	
	@kind("cat") static struct Cat { string name; }
	@kind("dog") static struct Dog { string name; }
	
	alias Pet = SumType!(Cat, Dog);
	
	static assert(hasKind!Cat);
	static assert(getKind!Cat.value == "cat");
	static assert(getKind!Dog.value == "dog");
}

private enum hasKind(T) = hasUDA!(T, Kind);
private enum getKind(T) = getUDAs!(T, Kind)[0];

// --------------------------------------------------------------------------
// converter / converterString 等 (シリアライズ・デシリアライズ用の変換関数UDA)
// --------------------------------------------------------------------------

/*******************************************************************************
 * カスタム変換コンバーター属性
 * 
 * シリアライズ時・デシリアライズ時の変換関数を一対で指定する。
 * Params:
 *     from = YamlValue → T の変換関数
 *     to   = T → YamlValue の変換関数
 */
auto converter(T1, T2)(void function(in T2, ref T1) @safe from, void function(in T1, ref T2) @safe to)
{
	alias FnFrom = typeof(from);
	alias FnTo   = typeof(to);
	static struct AttrConverter
	{
		FnFrom from;
		FnTo   to;
	}
	return AttrConverter(from, to);
}

/// ditto
auto converter(T1, T2)(T1 function(in T2) @safe from, T2 function(in T1) @safe to)
{
	alias FnFrom = typeof(from);
	alias FnTo   = typeof(to);
	static struct AttrConverter
	{
		FnFrom from;
		FnTo   to;
	}
	return AttrConverter(from, to);
}

/// ditto
auto converterString(T)(T function(string) @safe from, string function(in T) @safe to)
	=> converter!T(from, to);

/// ditto
alias convStr = converterString;
///
@safe unittest
{
	static struct Point
	{
		int x;
		int y;
		
		static Point fromStr(string s) @safe
		{
			import std.string : split;
			import std.conv   : to;
			auto parts = s.split(",");
			return Point(parts[0].to!int, parts[1].to!int);
		}
		static string toStr(in Point p) @safe
		{
			import std.conv : text;
			return text(p.x, ",", p.y);
		}
	}
	// フィールド宣言に `@convStr!Point(...)` を直接書くとCTFEの制約で
	// コンパイルできないため、名前付きの引数無し関数でラップして使用する。
	static auto convPoint() => convStr!Point(&Point.fromStr, &Point.toStr);
	static struct Data
	{
		@convPoint
		Point pt;
	}
	auto v = serializeToYaml(Data(Point(1, 2)));
	assert(v.getValue!string("pt") == "1,2");
	auto d = deserializeFromYaml!Data(v);
	assert(d.pt == Point(1, 2));
}

// --------------------------------------------------------------------------
// CommentType / comment 属性
// --------------------------------------------------------------------------

///
enum CommentType
{
	/// キーまたは値の直前に置く行コメント
	line,
	/// キーまたは値と同一行の末尾に置く行末コメント
	trailing,
}

private struct AttrYamlComment
{
	string    value;
	CommentType type;
}

private enum hasAttrYamlComment(alias variable)   = hasUDA!(variable, AttrYamlComment);
private enum getAttrYamlComments(alias variable)   = getUDAs!(variable, AttrYamlComment);
private enum getAttrYamlComment(alias variable)    = getAttrYamlComments!variable[0];

/*******************************************************************************
 * YAMLコメント属性
 * 
 * シリアライズ時に対象フィールドに対してコメントを付与する。
 * Params:
 *     cmt  = コメント本文（`#` は不要）
 *     type = コメント種別（既定: line）
 */
auto comment(string cmt, CommentType type = CommentType.line) @safe
{
	return AttrYamlComment(cmt, type);
}
///
@safe unittest
{
	// `#`の直後に空白は自動挿入されないため、そろえたい場合は
	// コメント本文の先頭に空白を含めて指定する。
	static struct Data
	{
		@comment(" ユーザーID")
		int id;
		@comment(" インライン注釈", CommentType.trailing)
		int age;
	}
	auto str = serializeToYamlString(Data(1, 20));
	assert(str == "# ユーザーID\nid: 1\nage: 20 # インライン注釈\n");
}

// --------------------------------------------------------------------------
// ScalarStyle / scalarStyle 属性
// --------------------------------------------------------------------------

///
enum ScalarStyle
{
	plain,        /// プレーンスカラー（クォートなし）
	singleQuoted, /// シングルクォート文字列
	doubleQuoted, /// ダブルクォート文字列
	literal,      /// ブロックスカラー literal (`|`)
	folded,       /// ブロックスカラー folded (`>`)
}

private struct AttrYamlScalarStyle
{
	ScalarStyle style;
}

private enum hasAttrYamlScalarStyle(alias variable) = hasUDA!(variable, AttrYamlScalarStyle);
private enum getAttrYamlScalarStyle(alias variable) = getUDAs!(variable, AttrYamlScalarStyle)[0];

/*******************************************************************************
 * YAMLスカラースタイル属性
 * 
 * シリアライズ時の文字列出力スタイルを指定する。
 * Params:
 *     style = スカラースタイル
 */
auto scalarStyle(ScalarStyle style) @safe
{
	return AttrYamlScalarStyle(style);
}
///
@safe unittest
{
	static struct Data
	{
		@scalarStyle(ScalarStyle.singleQuoted)
		string name;
	}
	auto str = serializeToYamlString(Data("Alice"));
	assert(str == "name: 'Alice'\n");
}

// --------------------------------------------------------------------------
// IntegerBase / integralFormat 属性
// --------------------------------------------------------------------------

///
enum IntegerBase
{
	decimal, /// 10進数
	hex,     /// 16進数 (0x...)
	octal,   /// 8進数  (0o...)
	binary,  /// 2進数  (0b...)
}

private struct AttrYamlIntegralFormat
{
	bool        positiveSign;
	IntegerBase base;
}

private enum hasAttrYamlIntegralFormat(alias variable) = hasUDA!(variable, AttrYamlIntegralFormat);
private enum getAttrYamlIntegralFormat(alias variable) = getUDAs!(variable, AttrYamlIntegralFormat)[0];

/*******************************************************************************
 * YAML整数フォーマット属性
 * 
 * シリアライズ時の整数値出力フォーマットを指定する。
 * Params:
 *     positiveSign = 正数に `+` 符号を付与するか
 *     base         = 基数（既定: decimal）
 */
auto integralFormat(bool positiveSign = false, IntegerBase base = IntegerBase.decimal) @safe
{
	return AttrYamlIntegralFormat(positiveSign, base);
}
///
@safe unittest
{
	static struct Data
	{
		@integralFormat(true, IntegerBase.hex)
		int flags;
	}
	auto str = serializeToYamlString(Data(255));
	assert(str == "flags: +0xff\n");
}

// --------------------------------------------------------------------------
// floatingPointFormat 属性
// --------------------------------------------------------------------------

private struct AttrYamlFloatingPointFormat
{
	bool   leadingDecimalPoint;
	bool   tailingDecimalPoint;
	bool   positiveSign;
	bool   withExponent;
	size_t precision;
}

private enum hasAttrYamlFloatingPointFormat(alias variable) = hasUDA!(variable, AttrYamlFloatingPointFormat);
private enum getAttrYamlFloatingPointFormat(alias variable) = getUDAs!(variable, AttrYamlFloatingPointFormat)[0];

/*******************************************************************************
 * YAML浮動小数点フォーマット属性
 * 
 * Params:
 *     leadingDecimalPoint  = 先頭に小数点を置く（`.5` 形式）
 *     tailingDecimalPoint  = 末尾に小数点を置く（`5.` 形式）
 *     positiveSign         = 正数に `+` 符号を付与するか
 *     withExponent         = 指数表記を使用するか
 *     precision            = 小数点以下の桁数（0 = 既定）
 */
auto floatingPointFormat(
	bool   leadingDecimalPoint = false,
	bool   tailingDecimalPoint = false,
	bool   positiveSign        = false,
	bool   withExponent        = false,
	size_t precision           = 0) @safe
{
	return AttrYamlFloatingPointFormat(
		leadingDecimalPoint, tailingDecimalPoint, positiveSign, withExponent, precision);
}
///
@safe unittest
{
	static struct Data
	{
		@floatingPointFormat(false, false, true, false, 2)
		double ratio;
	}
	auto str = serializeToYamlString(Data(0.5));
	assert(str == "ratio: +0.50\n");
}

// --------------------------------------------------------------------------
// CollectionStyle / arrayFormat / mappingFormat 属性
// --------------------------------------------------------------------------

///
enum CollectionStyle
{
	block, /// ブロックスタイル（インデントベース）
	flow,  /// フロースタイル（`[...]` / `{...}`）
}

private struct AttrYamlArrayFormat
{
	CollectionStyle style;
	bool            trailingComma; /// flow限定: 末尾カンマを付与するか
	bool            singleLine;    /// flow限定: 1行で出力するか
}

private enum hasAttrYamlArrayFormat(alias variable) = hasUDA!(variable, AttrYamlArrayFormat);
private enum getAttrYamlArrayFormat(alias variable) = getUDAs!(variable, AttrYamlArrayFormat)[0];

/*******************************************************************************
 * YAMLシーケンスフォーマット属性
 * 
 * Params:
 *     style         = block または flow（既定: block）
 *     trailingComma = flow時に末尾カンマを付与するか
 *     singleLine    = flow時に1行で出力するか
 */
auto arrayFormat(
	CollectionStyle style         = CollectionStyle.block,
	bool            trailingComma = false,
	bool            singleLine    = false) @safe
{
	return AttrYamlArrayFormat(style, trailingComma, singleLine);
}
///
@safe unittest
{
	static struct Data
	{
		@arrayFormat(CollectionStyle.flow, true, true)
		int[] values;
	}
	auto str = serializeToYamlString(Data([1, 2, 3]));
	assert(str == "values: [1, 2, 3,]\n");
}

/// ケツカンマ付き1行フロー記法シーケンス
enum singleLineAry = arrayFormat(CollectionStyle.flow, true, true);

private struct AttrYamlMappingFormat
{
	CollectionStyle style;
	bool            trailingComma;
	bool            singleLine;
}

private enum hasAttrYamlMappingFormat(alias variable) = hasUDA!(variable, AttrYamlMappingFormat);
private enum getAttrYamlMappingFormat(alias variable) = getUDAs!(variable, AttrYamlMappingFormat)[0];

/*******************************************************************************
 * YAMLマッピングフォーマット属性
 * 
 * Params:
 *     style         = block または flow（既定: block）
 *     trailingComma = flow時に末尾カンマを付与するか
 *     singleLine    = flow時に1行で出力するか
 */
auto mappingFormat(
	CollectionStyle style         = CollectionStyle.block,
	bool            trailingComma = false,
	bool            singleLine    = false) @safe
{
	return AttrYamlMappingFormat(style, trailingComma, singleLine);
}
///
@safe unittest
{
	static struct Point { int x; int y; }
	static struct Data
	{
		@mappingFormat(CollectionStyle.flow, false, true)
		Point pos;
	}
	auto str = serializeToYamlString(Data(Point(1, 2)));
	assert(str == "pos: {x: 1, y: 2}\n");
}

/// ケツカンマ付き1行フロー記法マッピング
enum singleLineMap = mappingFormat(CollectionStyle.flow, true, true);

// --------------------------------------------------------------------------
// keyStyle 属性（マッピングキーのスカラースタイル指定）
// --------------------------------------------------------------------------

private struct AttrYamlKeyStyle
{
	ScalarStyle style;
}

private enum hasAttrYamlKeyStyle(alias variable) = hasUDA!(variable, AttrYamlKeyStyle);
private enum getAttrYamlKeyStyle(alias variable) = getUDAs!(variable, AttrYamlKeyStyle)[0];

/*******************************************************************************
 * YAMLマッピングキースタイル属性
 * 
 * マッピングキーの出力スタイルを指定する。
 * `ScalarStyle.literal` / `ScalarStyle.folded` は指定不可（コンパイルエラー）。
 * Params:
 *     style = plain / singleQuoted / doubleQuoted のいずれか
 */
auto keyStyle(ScalarStyle style) @safe
{
	assert(style != ScalarStyle.literal && style != ScalarStyle.folded,
		"keyStyle does not support literal or folded style");
	return AttrYamlKeyStyle(style);
}

/// ditto
enum plainKey       = keyStyle(ScalarStyle.plain);
/// ditto
enum singleQuotedKey = keyStyle(ScalarStyle.singleQuoted);
/// ditto
enum doubleQuotedKey = keyStyle(ScalarStyle.doubleQuoted);
///
@safe unittest
{
	static struct Data
	{
		@doubleQuotedKey
		int id;
	}
	auto str = serializeToYamlString(Data(1));
	assert(str == "\"id\": 1\n");
}

// --------------------------------------------------------------------------
// anchor 属性（シリアライズ時にアンカーを付与する）
// --------------------------------------------------------------------------

private struct AttrYamlAnchor
{
	string anchorName;
}

private enum hasAttrYamlAnchor(alias variable) = hasUDA!(variable, AttrYamlAnchor);
private enum getAttrYamlAnchor(alias variable) = getUDAs!(variable, AttrYamlAnchor)[0];

/*******************************************************************************
 * YAMLアンカー属性
 * 
 * シリアライズ時に対象フィールドに `&name` アンカーを付与する。
 * Params:
 *     anchorName = アンカー名
 */
auto anchor(string anchorName) @safe
{
	return AttrYamlAnchor(anchorName);
}
///
@safe unittest
{
	static struct Data
	{
		@anchor("theId")
		int id;
	}
	auto str = serializeToYamlString(Data(1));
	assert(str == "id: &theId 1\n");
}

// --------------------------------------------------------------------------
// tag 属性（明示タグ）
// --------------------------------------------------------------------------

private struct AttrYamlTag
{
	string tagName;
}

private enum hasAttrYamlTag(alias variable) = hasUDA!(variable, AttrYamlTag);
private enum getAttrYamlTag(alias variable) = getUDAs!(variable, AttrYamlTag)[0];

/*******************************************************************************
 * YAML明示タグ属性
 * 
 * シリアライズ時に対象フィールドに `!!tagName` を付与する。
 * パース側では保持のみを行い、型解決には使用しない。
 * Params:
 *     tagName = タグ名（`!!` プレフィックスを除いた名称）
 */
auto tag(string tagName) @safe
{
	return AttrYamlTag(tagName);
}
///
@safe unittest
{
	static struct Data
	{
		@tag("MyType")
		int id;
	}
	auto str = serializeToYamlString(Data(1));
	assert(str == "id: !!MyType 1\n");
}

// ============================================================================
// MARK: Traits
// ============================================================================

/*******************************************************************************
 * バイナリ型（`immutable(ubyte)[]`）かどうかを判定する
 */
enum isBinary(T) = is(T == immutable(ubyte)[]);

private enum isArrayWithoutBinary(T) = isArray!T && !isBinary!T;

/*******************************************************************************
 * Tuple がシリアライズ可能かどうかを判定する
 */
enum isSerializableTuple(T) = isTuple!T && allSatisfy!(isSerializable, T.Types);

/*******************************************************************************
 * SumType がシリアライズ可能かどうかを判定する
 * 
 * 以下の条件をすべて満たす場合に true を返す:
 * - `T` は SumType である
 * - 全メンバーが isSerializable を満たす
 * - aggregate型メンバーはすべて `@kind` 属性を持つ
 * - integral/floating/boolean/string/binary/array/AA はそれぞれ最大1つ
 */
enum isSerializableSumType(T) = isSumType!T
	&& allSatisfy!(isSerializable, T.Types)
	&& allSatisfy!(hasKind, Filter!(isAggregateType, T.Types))
	&& Filter!(isIntegral,          T.Types).length <= 1
	&& Filter!(isFloatingPoint,     T.Types).length <= 1
	&& Filter!(isBoolean,           T.Types).length <= 1
	&& Filter!(isSomeString,        T.Types).length <= 1
	&& Filter!(isBinary,            T.Types).length <= 1
	&& Filter!(isAssociativeArray,  T.Types).length <= 1;

// `YamlValue`はBuilder型が確定した具体型のエイリアスであるため、
// `isInstanceOf!(YamlValue, T)`では判定できない(常にfalseになる)。
// `is()`パターンマッチでテンプレート`YamlValueImpl`自体を判定する。
private enum isYamlValue(T) = is(T == YamlValueImpl!Builder, Builder);
private template builderOf(T)
{
	static if (is(T == YamlValueImpl!Builder, Builder))
		alias builderOf = Builder;
}

// toYaml / fromYaml フック検出
private template hasConvertYamlMethodA(T)
{
	static if (is(typeof(T.toYaml)))
	{
		alias YamlValueT = ReturnType!(T.toYaml);
		static if (isYamlValue!YamlValueT)
		{
			alias BuilderT = builderOf!YamlValueT;
			enum bool hasConvertYamlMethodA =
				is(typeof(T.toYaml(lvalueOf!BuilderT)) == YamlValueT)
				&& is(typeof(T.fromYaml(lvalueOf!YamlValueT)) == T);
		}
		else
		{
			enum bool hasConvertYamlMethodA = false;
		}
	}
	else
	{
		enum bool hasConvertYamlMethodA = false;
	}
}

private template hasConvertYamlMethodB(T)
{
	static if (is(typeof(T.toYaml)))
	{
		alias YamlValueT = ReturnType!(T.toYaml);
		static if (isYamlValue!YamlValueT)
		{
			alias BuilderT = builderOf!YamlValueT;
			enum bool hasConvertYamlMethodB =
				is(typeof(T.toYaml()) == YamlValueT)
				&& is(typeof(T.fromYaml(lvalueOf!YamlValueT)) == T);
		}
		else
		{
			enum bool hasConvertYamlMethodB = false;
		}
	}
	else
	{
		enum bool hasConvertYamlMethodB = false;
	}
}

private enum hasConvertYamlMethod(T) = hasConvertYamlMethodA!T || hasConvertYamlMethodB!T;

private enum isSerializableData(T) = isIntegral!T
	|| isFloatingPoint!T
	|| isBoolean!T
	|| isSomeString!T
	|| isBinary!T
	|| isArray!T
	|| isAssociativeArray!T
	|| (isAggregateType!T
		&& !hasElaborateAssign!T
		&& !hasElaborateCopyConstructor!T
		&& !hasElaborateMove!T
		&& !hasElaborateDestructor!T
		&& !hasNested!T
		&& !isSumType!T)
	|| (isAggregateType!T && hasConvertYamlMethod!T);

private enum isAccessible(alias var) =
	__traits(getVisibility, var).startsWith("public", "export") != 0;

/*******************************************************************************
 * 型が YAML としてシリアライズ可能かどうかを判定する
 */
template isSerializable(T)
{
	static if (isArray!T && !isBinary!T && !isSomeString!T)
		enum isSerializable = isSerializable!(ElementType!T);
	else static if (isAssociativeArray!T)
		enum isSerializable = isSerializable!(KeyType!T) && isSerializable!(ValueType!T);
	else static if (isSerializableSumType!T)
		enum isSerializable = true;
	else static if (isSerializableTuple!T)
		enum isSerializable = true;
	else static if (isAggregateType!T && !isSumType!T && !isInstanceOf!(Tuple, T))
		enum isSerializable = () {
			bool ret = true;
			static foreach (var; Filter!(isAccessible, T.tupleof[]))
				ret &= hasIgnore!var || hasValue!var || isSerializable!(typeof(var));
			return ret;
		}();
	else
		enum isSerializable = isSerializableData!T;
}

// ============================================================================
// MARK: Default Allocator
// ============================================================================

/*******************************************************************************
 * 既定のアロケータ
 * 
 * GCベースの実装。`YamlBuilderImpl` に `mixin` して使用する。
 * アロケータを差し替える場合は同一のインターフェースを持つ別の
 * `mixin template` を用意し、`YamlBuilderImpl(alias allocator)` に渡す。
 */
mixin template YamlDefaultAllocator()
{
	enum String: string { init = string.init }
	struct Dictionary(K, V)
	{
	private:
		struct Item
		{
			K key;
			V value;
		}
		Item[] items;
	public:
		///
		ref inout(Item[]) byKeyValue() inout @safe => items;
		///
		auto prepend(K k, V v) @safe => items = Item(k, v) ~ items;
		///
		auto append(K k, V v) @safe => items ~= Item(k, v);
		///
		bool empty() const @safe => items.length == 0;
		///
		size_t length() const @safe => items.length;
		///
		inout(V)* opIn(K key) inout @safe
		{
			foreach (ref item; items)
			{
				if (item.key == key)
					return &item.value;
			}
			return null;
		}
		///
		ref inout(Item) opIndex(size_t idx) inout @safe => items[idx];
		///
		ref inout(V) opIndex(K key) inout @safe
		{
			if (auto p = this.opIn(key))
				return *p;
			throw new Exception(format("Key '%s' not found", key));
		}
	}
	template Array(T) { enum Array: T[] { init = T[].init } }
	
	auto allocStr()() @safe => String.init;
	auto allocStr()(string s) @safe => cast(String)s;
	auto allocDic(K, V)() @safe => Dictionary!(K, V).init;
	auto allocAry(T)() @safe => Array!T.init;
	
	void clearAry(Ary)(ref Ary ary) @safe { ary = null; }
	auto copyStr()(in String str) @safe => cast(String)str[];
}

// ============================================================================
// MARK: - YamlValue
// ============================================================================

/*******************************************************************************
 * ブロックスカラーのchomping指定子
 */
enum ChompingIndicator
{
	clip,  /// 既定。末尾改行を1つだけ残す
	strip, /// `-` 指定。末尾改行をすべて除去する
	keep,  /// `+` 指定。末尾の空行もすべて残す
}

/*******************************************************************************
 * YAML値
 * 
 * `Builder` は `YamlBuilderImpl` を指定する。アロケータの違いにより
 * 別々の `Builder` 型を指定することで、異なるメモリ管理方式のツリーを構築できる。
 */
static struct YamlValueImpl(Builder)
{
	// `_comments`/`_instance`等のprivateフィールドは`Array!Comment`/`YamlType`
	// (SumType)をテンプレート実体化するため、これらの型定義(直後の
	// YamlTypesセクション)が先に完結している必要がある(Dの言語仕様上の制約)。
	// そのため型定義を最初に置き、privateセクションはその直後に配置する。
	// ==========================================================================
	// MARK: - - YamlTypes
	// ==========================================================================
	///
	alias String = Builder.String;
	///
	alias Dictionary = Builder.Dictionary;
	///
	alias Array = Builder.Array;
	
	///
	static struct YamlString
	{
		///
		String value;
		/// 出力スタイル（plain/singleQuoted/doubleQuoted/literal/folded）
		ScalarStyle style = ScalarStyle.plain;
		/// パース時の元テキスト。空でなければstringify時に他のフィールド(style等)より
		/// 優先してそのまま出力される（値を書き換えた場合はこのフィールドをクリアする）
		String raw;
		/// ブロックスカラー(literal/folded)のchomping指定子
		ChompingIndicator chomping = ChompingIndicator.clip;
		/// ブロックスカラーの明示インデント指定（未指定ならNullable.null）
		Nullable!ubyte explicitIndent;
		
		///
		alias value this;
	}
	///
	static struct YamlInteger
	{
		///
		long value;
		///
		bool positiveSign;
		///
		IntegerBase base = IntegerBase.decimal;
		/// パース時の元テキスト。空でなければstringify時に他のフィールドより優先して
		/// そのまま出力される（値を書き換えた場合はこのフィールドをクリアする）
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlUInteger
	{
		///
		ulong value;
		///
		bool positiveSign;
		///
		IntegerBase base = IntegerBase.decimal;
		/// パース時の元テキスト。空でなければstringify時に他のフィールドより優先して
		/// そのまま出力される（値を書き換えた場合はこのフィールドをクリアする）
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlFloatingPoint
	{
		///
		double value;
		///
		bool leadingDecimalPoint;
		///
		bool tailingDecimalPoint;
		///
		bool positiveSign;
		///
		bool withExponent;
		///
		size_t precision;
		/// パース時の元テキスト。空でなければstringify時に他のフィールドより優先して
		/// そのまま出力される（値を書き換えた場合はこのフィールドをクリアする）
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlBoolean
	{
		///
		bool value;
		/// パース時の元テキスト（`true`/`True`/`yes`/`on` 等）。空でなければstringify時に
		/// `value`より優先してそのまま出力される
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlNull
	{
		/// パース時の元テキスト（`~`/`null`/空文字列 等）。空でなければstringify時に
		/// そのまま出力される
		String raw;
	}
	///
	static struct YamlKey
	{
		///
		String value;
		/// キーの出力スタイル。`literal`/`folded`はマッピングキーには使えないため
		/// 指定できない（指定するとstringify時にアサーション違反になる）
		ScalarStyle style = ScalarStyle.plain;
		///
		bool opEquals(in YamlKey lhs) const
		{
			return value[] == lhs.value[];
		}
		///
		size_t toHash() const
		{
			return value[].hashOf();
		}
	}
	///
	static struct YamlMapping
	{
		///
		Dictionary!(YamlKey, YamlValueImpl) value;
		///
		CollectionStyle style = CollectionStyle.block;
		/// flow限定
		bool trailingComma;
		/// flow限定
		bool singleLine;
		/// ぶら下がりコメント。末尾の要素より後、コレクションが終わる位置までの
		/// 範囲に出現し、どの子要素にも属さないコメント
		Array!Comment trailingComments;
		
		///
		ref inout(Dictionary!(YamlKey, YamlValueImpl).Item) opIndex()(size_t idx) inout => value[idx];
		///
		ref inout(YamlValueImpl) opIndex()(string key) inout
		{
			foreach (ref itm; value.byKeyValue)
			{
				if (itm.key.value[] == key)
					return itm.value;
			}
			throw new Exception(format("Key '%s' not found", key));
		}
		
		///
		alias value this;
	}
	///
	static struct YamlSequence
	{
		///
		Array!YamlValueImpl value;
		///
		CollectionStyle style = CollectionStyle.block;
		/// flow限定
		bool trailingComma;
		/// flow限定
		bool singleLine;
		/// ぶら下がりコメント。末尾の要素より後、コレクションが終わる位置までの
		/// 範囲に出現し、どの子要素にも属さないコメント
		Array!Comment trailingComments;
		
		///
		alias value this;
	}
	///
	static struct YamlAlias
	{
		/// 参照先アンカー名
		String value;
		/// 参照先ノードの複製（ヒープ確保）。元のノードとは独立しているため
		/// 一方を更新してももう一方には影響しない
		YamlValueImpl* resolved;
		
		///
		alias value this;
	}
	///
	enum UndefinedValue { init }
	///
	alias YamlType = SumType!(
		UndefinedValue,
		YamlAlias,
		YamlString,
		YamlInteger,
		YamlUInteger,
		YamlFloatingPoint,
		YamlBoolean,
		YamlSequence,
		YamlMapping,
		YamlNull);
	
	///
	static struct LineComment
	{
		///
		String value;
		///
		alias value this;
	}
	
	///
	static enum TrailingComment: LineComment { init = LineComment.init }
	
	///
	alias Comment = SumType!(
		LineComment,
		TrailingComment);
	
	///
	enum Type: ubyte
	{
		undefined,
		alias_,
		string,
		integer,
		uinteger,
		floating,
		boolean,
		sequence,
		mapping,
		nullfied,
	}
private:
	// ==========================================================================
	// MARK: - - Internal Fields / Helpers
	// ==========================================================================
	Array!Comment   _comments;
	Nullable!String _anchor;
	Nullable!String _tag;
	YamlType        _instance;
	Builder*        _builder;
	
	/// `undefinedValue()`等、値未確定のインスタンスを作るための内部コンストラクタ
	this(scope ref Builder builder) @system pure nothrow @nogc
	{
		_builder = &builder;
	}
	
	ref inout(Dictionary!(YamlKey, YamlValueImpl)) _reqMap() pure inout @trusted
	{
		enum idx = staticIndexOf!(YamlMapping, YamlType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	ref inout(Array!YamlValueImpl) _reqSeq() pure inout @trusted
	{
		enum idx = staticIndexOf!(YamlSequence, YamlType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	ref inout(String) _reqStr() pure inout @trusted
	{
		enum idx = staticIndexOf!(YamlString, YamlType.Types);
		return __traits(getMember, _instance, "storage").tupleof[idx].value;
	}
	void _assignInst(T)(T v) @trusted
	{
		_instance = v;
	}
	ref inout(YamlAlias) asAliasRaw() inout nothrow pure @nogc @trusted
	{
		assert(type == Type.alias_, "Not an alias type");
		return __traits(getMember, _instance, "storage").tupleof[cast(size_t)Type.alias_];
	}
	
public:
	// ==========================================================================
	// MARK: - - Constructor/Destructor/Assign
	// ==========================================================================
	/***************************************************************************
	 * `Builder`に紐付いた値を構築する
	 * 
	 * `val`は`opAssign`が受理する型であれば何でもよい。通常は直接呼び出さず、
	 * `Builder.make()`等のBuilder Factory API経由で構築する。
	 */
	this(T)(T val, scope ref Builder builder) pure return @system
	{
		_builder = &builder;
		opAssign(val);
	}
	
	/***************************************************************************
	 * 破棄時に`Builder`側のリソース解放処理へ通知する
	 */
	~this() pure nothrow @nogc @safe
	{
		if (_builder)
			_builder.dispose(this);
	}
	
	/***************************************************************************
	 * 値を代入する
	 * 
	 * 文字列・整数・符号なし整数・浮動小数点・真偽値・`null`・配列・
	 * 連想配列（キーは`string`）・各`Yaml*`構造体そのもの・他の`YamlValueImpl`を
	 * 受理する。それ以外の型を渡すとコンパイルエラーになる。
	 */
	ref YamlValueImpl opAssign(T)(T value) pure return @trusted
	{
		alias U = Unqual!T;
		static if (is(T == YamlValueImpl))
		{
			_builder  = value._builder;
			_comments = value._comments;
			_anchor   = value._anchor;
			_tag      = value._tag;
			_instance = value._instance;
		}
		else static if (is(U == string))
		{
			auto tmp = YamlString(_builder.allocStr());
			tmp.value ~= value;
			_instance = tmp;
		}
		else static if (isSomeString!U)
		{
			import std.utf;
			auto tmp = YamlString(_builder.allocStr());
			tmp.value ~= value.toUTF8();
			_instance = tmp;
		}
		else static if (isIntegral!U && isSigned!U)
			_instance = YamlInteger(value);
		else static if (isIntegral!U && isUnsigned!U)
			_instance = YamlUInteger(value);
		else static if (isFloatingPoint!U)
			_instance = YamlFloatingPoint(value);
		else static if (isBoolean!U)
			_instance = YamlBoolean(value);
		else static if (is(U == typeof(null)))
			_instance = YamlNull.init;
		else static if (isArray!T)
		{
			auto ary = _builder.allocAry!YamlValueImpl;
			foreach (ref v; value)
				ary ~= YamlValueImpl(v, *_builder);
			_instance = YamlSequence(ary);
		}
		else static if (isAssociativeArray!T && is(KeyType!T == string))
		{
			auto tmp = _builder.allocDic!(YamlKey, YamlValueImpl);
			foreach (ref k, ref v; value)
				tmp.append(YamlKey(cast(String)k), YamlValueImpl(v, *_builder));
			_instance = YamlMapping(tmp);
		}
		else static if (is(U == YamlString))
			_instance = value;
		else static if (is(U == YamlInteger))
			_instance = value;
		else static if (is(U == YamlUInteger))
			_instance = value;
		else static if (is(U == YamlFloatingPoint))
			_instance = value;
		else static if (is(U == YamlBoolean))
			_instance = value;
		else static if (is(U == YamlNull))
			_instance = value;
		else static if (is(T == YamlSequence))
			_instance = value;
		else static if (is(T == YamlMapping))
			_instance = value;
		else static if (is(T == YamlAlias))
			_instance = value;
		else static assert(0, "Cannot assign a value of type " ~ T.stringof ~ " to YamlValueImpl");
		return this;
	}
	
	/***************************************************************************
	 * この値が実際に持っている型(`Type`)を取得する
	 * 
	 * エイリアスノードの場合は解決せず`Type.alias_`を返す(参照先の型を
	 * 知りたい場合は`dereference().type`とする)。
	 */
	Type type() const nothrow pure @nogc @trusted
	{
		return cast(Type)__traits(getMember, _instance, "tag");
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.make(42);
		assert(v.type == YamlBuilder.YamlType.integer);
		auto s = builder.make("hello");
		assert(s.type == YamlBuilder.YamlType.string);
	}
	
	// ==========================================================================
	// MARK: - - Alias Resolution
	// ==========================================================================
	
	/***************************************************************************
	 * エイリアスノードであれば参照先の実体を、そうでなければ自分自身を返す
	 * 
	 * 全アクセサはこのメソッドを経由することで、エイリアスの有無を意識せず
	 * 透過的に値へアクセスできる。エイリアスがさらにエイリアスを指す連鎖
	 * （`&y *x`のようにエイリアスノード自体にアンカーを付けた場合に 発生しうる）
	 * にも対応するため、`resolved`がさらにエイリアス型であれば再帰的に辿る。
	 */
	ref inout(YamlValueImpl) dereference() inout @trusted
	{
		if (type == Type.alias_)
			return (*asAliasRaw().resolved).dereference();
		return this;
	}
	
	/***************************************************************************
	 * エイリアス自体（未解決の参照情報）を取得する
	 */
	ref inout(YamlAlias) asAlias() inout nothrow pure @nogc @trusted
	{
		return asAliasRaw();
	}
	
	// ==========================================================================
	// MARK: - - Accessor
	// ==========================================================================
	
	/***************************************************************************
	 * 文字列として値へアクセスする
	 * 
	 * この値が文字列型でない場合はアサーション違反になる。事前に`type`で
	 * 確認するか、型を問わず取得したい場合は`get!string`を使う。
	 */
	ref inout(YamlString) asString() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.string, "Not a string type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.string];
	}
	
	/***************************************************************************
	 * 符号付き整数として値へアクセスする(この値が整数型でない場合はアサーション違反)
	 */
	ref inout(YamlInteger) asInteger() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.integer, "Not an integer number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.integer];
	}
	
	/***************************************************************************
	 * 符号なし整数として値へアクセスする(この値が符号なし整数型でない場合はアサーション違反)
	 */
	ref inout(YamlUInteger) asUInteger() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.uinteger, "Not an unsigned integer number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.uinteger];
	}
	
	/***************************************************************************
	 * 浮動小数点数として値へアクセスする(この値が浮動小数点型でない場合はアサーション違反)
	 */
	ref inout(YamlFloatingPoint) asFloatingPoint() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.floating, "Not a floating point number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.floating];
	}
	
	/***************************************************************************
	 * 真偽値として値へアクセスする(この値が真偽値型でない場合はアサーション違反)
	 */
	ref inout(YamlBoolean) asBoolean() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.boolean, "Not a boolean type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.boolean];
	}
	
	/***************************************************************************
	 * マッピングとして値へアクセスする(この値がマッピング型でない場合はアサーション違反)
	 */
	ref inout(YamlMapping) asMapping() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.mapping, "Not a mapping type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.mapping];
	}
	/// ditto
	alias asObject = asMapping;
	
	/***************************************************************************
	 * シーケンスとして値へアクセスする(この値がシーケンス型でない場合はアサーション違反)
	 */
	ref inout(YamlSequence) asSequence() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.sequence, "Not a sequence type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.sequence];
	}
	/// ditto
	alias asArray = asSequence;
	
	/***************************************************************************
	 * null値として値へアクセスする(この値がnull型でない場合はアサーション違反)
	 */
	ref inout(YamlNull) asNull() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.nullfied, "Not a null type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.nullfied];
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.parse("name: Alice\nage: 20\nheight: 1.6\nactive: true\n");
		
		// 各`asXxx()`は対応する型の値へ直接アクセスするための参照を返す。
		// 型が一致しない場合はアサーション違反になるため、型が事前に
		// 分かっている場合に使う（型を問わず取得したい場合は`get!T`を使う）。
		assert(v.asMapping["name"].asString.value[] == "Alice");
		assert(v.asMapping["age"].asInteger.value == 20);
		assert(v.asMapping["height"].asFloatingPoint.value == 1.6);
		assert(v.asMapping["active"].asBoolean.value == true);
		
		// マッピング・シーケンスは`asMapping`/`asSequence`(`asObject`/`asArray`は別名)
		auto seq = builder.make([1, 2, 3]);
		assert(seq.asSequence.value.length == 3);
		assert(seq.asArray.value.length == 3);
	}
	
	/***************************************************************************
	 * Get value as the given type
	 * 
	 * If the type conversion is not possible, return the given default value (or T.init if not given).
	 * エイリアスは自動的に解決される。
	 */
	T get(T)(lazy T defaultValue = T.init) inout @safe
	{
		try
		{
			auto instp = &(dereference()._instance);
			static if (is(T == string))
			{
				return (*instp).match!(
					(in YamlString val) => val.value,
					(in _) => defaultValue);
			}
			else static if (isIntegral!T && isSigned!T)
			{
				return (*instp).match!(
					(in YamlInteger val) => cast(T)val.value,
					(in YamlUInteger val) => cast(T)val.value,
					(in YamlFloatingPoint val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isIntegral!T && isUnsigned!T)
			{
				return (*instp).match!(
					(in YamlUInteger val) => cast(T)val.value,
					(in YamlInteger val) => cast(T)val.value,
					(in YamlFloatingPoint val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isFloatingPoint!T)
			{
				return (*instp).match!(
					(in YamlFloatingPoint val) => cast(T)val.value,
					(in YamlInteger val) => cast(T)val.value,
					(in YamlUInteger val) => cast(T)val.value,
					(in _) => defaultValue);
			}
			else static if (isBoolean!T)
			{
				return (*instp).match!(
					(in YamlBoolean val) => val.value,
					(in YamlInteger val) => val.value != 0,
					(in YamlUInteger val) => val.value != 0,
					(in YamlString val) => val.value != "",
					(in _) => defaultValue);
			}
			else static if (is(T == typeof(null)))
			{
				return (*instp).match!(
					(in YamlNull val) => null,
					(in YamlString val) => val.value.length == 0 ? null : defaultValue,
					(in YamlSequence val) => val.value.length == 0 ? null : defaultValue,
					(in YamlMapping val) => val.value.byKeyValue.empty ? null : defaultValue,
					(in _) => defaultValue);
			}
			else static if (isDynamicArray!T)
			{
				return (*instp).match!(
					(in YamlSequence val) {
						T ret;
						foreach (ref elm; val.value)
							ret ~= elm.get!(ElementType!T)();
						return ret;
					},
					(in _) => defaultValue);
			}
			else static if (isAssociativeArray!T && is(KeyType!T == string))
			{
				return (*instp).match!(
					(in YamlMapping val) {
						T ret;
						foreach (ref kv; val.value.byKeyValue)
							ret[kv.key.value] = kv.value.get!(ValueType!T)();
						return ret;
					},
					(in _) => defaultValue);
			}
			else static if (is(T == YamlString))
				return (*instp).match!((in YamlString val) => val, (in _) => defaultValue);
			else static if (is(T == YamlInteger))
				return (*instp).match!((in YamlInteger val) => val, (in _) => defaultValue);
			else static if (is(T == YamlUInteger))
				return (*instp).match!((in YamlUInteger val) => val, (in _) => defaultValue);
			else static if (is(T == YamlFloatingPoint))
				return (*instp).match!((in YamlFloatingPoint val) => val, (in _) => defaultValue);
			else static if (is(T == YamlSequence))
				return (*instp).match!((in YamlSequence val) => val, (in _) => defaultValue);
			else static if (is(T == YamlMapping))
				return (*instp).match!((in YamlMapping val) => val, (in _) => defaultValue);
			else static assert(0, "Unsupported type for get!" ~ T.stringof);
		}
		catch (Exception e1)
		{
			try return defaultValue;
			catch (Exception e2)
				assert(0);
		}
	}
	/// ditto
	T getValue(T)(string key, lazy T defaultValue = T.init) inout @safe
	{
		assert(dereference().type == Type.mapping, "Not a mapping type");
		try
		{
			foreach (ref kv; dereference()._reqMap.byKeyValue)
			{
				if (kv.key.value[] == key)
					return kv.value.get!T(defaultValue);
			}
			return defaultValue;
		}
		catch (Exception e)
		{
			try return defaultValue;
			catch (Exception e2)
				return T.init;
		}
	}
	/// ditto
	T getElement(T)(size_t idx, lazy T defaultValue = T.init) inout @safe
	{
		assert(dereference().type == Type.sequence, "Not a sequence type");
		try
		{
			auto seqp = &dereference()._reqSeq();
			if (idx < seqp.length)
				return (*seqp)[idx].get!T(defaultValue);
			return defaultValue;
		}
		catch (Exception e)
		{
			try return defaultValue;
			catch (Exception e2)
				return T.init;
		}
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.parse("name: Alice\nage: 20\ntags: [a, b, c]\n");
		
		// get!T(): このノード自身の値を型を問わずTへ変換して取得する
		auto nameNode = v.asMapping["name"];
		assert(nameNode.get!string() == "Alice");
		assert(nameNode.get!int(-1) == -1); // 文字列をintとして解釈できないため既定値
		
		// getValue!T(key, default): マッピングの特定キーの値をTとして取得する
		assert(v.getValue!string("name") == "Alice");
		assert(v.getValue!int("age") == 20);
		assert(v.getValue!int("nosuch", -1) == -1); // 存在しないキーは既定値
		
		// getElement!T(idx, default): シーケンスの特定要素をTとして取得する
		auto tagsNode = v.asMapping["tags"];
		assert(tagsNode.getElement!string(0) == "a");
		assert(tagsNode.getElement!string(10, "none") == "none"); // 範囲外は既定値
	}
	
	// ==========================================================================
	// MARK: - - Comment
	// ==========================================================================
	
	/***************************************************************************
	 * Get number of comments
	 */
	size_t getCommentLength() const @safe
	{
		return _comments.length;
	}
	
	/***************************************************************************
	 * 行コメント/行末コメントを追加する
	 */
	void addComment(in char[] comment, CommentType type = CommentType.line) @safe
	{
		final switch (type)
		{
		case CommentType.line:
			addLineComment(comment);
			break;
		case CommentType.trailing:
			addTrailingComment(comment);
			break;
		}
	}
	/// ditto
	void addLineComment(in char[] comment) @safe
	{
		auto c = _builder.allocStr();
		c ~= comment;
		_comments ~= YamlValueImpl.Comment(YamlValueImpl.LineComment(c));
	}
	/// ditto
	void addTrailingComment(in char[] comment) @safe
	{
		auto c = _builder.allocStr();
		c ~= comment;
		_comments ~= YamlValueImpl.Comment(YamlValueImpl.TrailingComment(c));
	}
	
	/***************************************************************************
	 * Clear all comments
	 */
	void clearComment() @safe
	{
		_builder.clearAry(_comments);
	}
	
	/***************************************************************************
	 * Check if the comment at the given index is a line comment/trailing comment
	 */
	bool isLineComment(size_t idx) const @safe
	{
		assert(idx < _comments.length, "Comment index out of range");
		return __traits(getMember, _comments[idx], "tag") == 0;
	}
	/// ditto
	bool isTrailingComment(size_t idx) const @safe
	{
		assert(idx + 1 == _comments.length, "Trailing comment index must be the last one");
		return __traits(getMember, _comments[idx], "tag") == 1;
	}
	/// ditto
	bool hasTrailingComment() const @safe
	{
		if (_comments.length == 0)
			return false;
		return isTrailingComment(size_t(_comments.length) - 1);
	}
	
	/***************************************************************************
	 * Reference comment as a line comment
	 */
	ref inout(LineComment) asLineComment(size_t index) inout @trusted
	{
		assert(index < _comments.length, "Comment index out of range");
		assert(isLineComment(index));
		return __traits(getMember, _comments[index], "storage").tupleof[0];
	}
	
	/***************************************************************************
	 * Reference comment as a trailing comment
	 */
	ref inout(TrailingComment) asTrailingComment(size_t index) inout @trusted
	{
		assert(index + 1 == _comments.length, "Trailing comment index must be the last one");
		assert(isTrailingComment(index));
		return __traits(getMember, _comments[index], "storage").tupleof[1];
	}
	
	/***************************************************************************
	 * Get a comment as a string
	 */
	string getComment(size_t index) const @safe
	{
		return _comments[index].match!(
			(ref const(LineComment) line) => line.value[].idup,
			(ref const(TrailingComment) line) => line.value[].idup);
	}
	/// ditto
	string getComments() const @safe
	{
		auto app = appender!(const(char)[][])();
		foreach (ref c; _comments[])
		{
			c.match!(
				(ref const(LineComment) line) => app ~= line.value[],
				(ref const(TrailingComment) line) => app ~= line.value[]);
		}
		return join((() @trusted => cast(string[])app.data)(), "\n");
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.make(1);
		v.addComment(" 設定値", CommentType.line);
		v.addComment(" 単位はミリ秒", CommentType.trailing);
		
		assert(v.getCommentLength == 2);
		assert(v.isLineComment(0));
		assert(v.isTrailingComment(1));
		assert(v.hasTrailingComment);
		assert(v.getComment(0) == " 設定値");
		assert(v.getComments() == " 設定値\n 単位はミリ秒");
		
		v.clearComment();
		assert(v.getCommentLength == 0);
	}
	
	// ==========================================================================
	// MARK: - - Anchor / Tag
	// ==========================================================================
	
	/***************************************************************************
	 * アンカー名を取得する（未設定ならNullable.null）
	 */
	Nullable!string anchorName() const @safe
	{
		if (_anchor.isNull)
			return Nullable!string.init;
		return nullable(cast(string)_anchor.get[]);
	}
	/// ditto
	void setAnchor(string name) @safe
	{
		auto c = _builder.allocStr();
		c ~= name;
		_anchor = nullable(cast(String)c);
	}
	/// ditto
	void clearAnchor() @safe
	{
		_anchor.nullify();
	}
	
	/***************************************************************************
	 * 明示タグを取得する（未設定ならNullable.null）
	 */
	Nullable!string tagName() const @safe
	{
		if (_tag.isNull)
			return Nullable!string.init;
		return nullable(cast(string)_tag.get[]);
	}
	/// ditto
	void setTag(string t) @safe
	{
		auto c = _builder.allocStr();
		c ~= t;
		_tag = nullable(cast(String)c);
	}
	/// ditto
	void clearTag() @safe
	{
		_tag.nullify();
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.make(1);
		assert(v.anchorName.isNull);
		assert(v.tagName.isNull);
		
		v.setAnchor("id1");
		v.setTag("MyType");
		assert(v.anchorName.get == "id1");
		assert(v.tagName.get == "MyType");
		
		auto app = appender!(char[])();
		builder.toPrettyString(app, v);
		assert(app.data == "&id1 !!MyType 1");
		
		v.clearAnchor();
		v.clearTag();
		assert(v.anchorName.isNull);
		assert(v.tagName.isNull);
	}
}

// ============================================================================
// MARK: Builder
// ============================================================================

/*******************************************************************************
 * YAMLパースエラー
 * 
 * 通常の `Exception` と区別して捕捉できるよう、専用の例外型として定義する。
 * メッセージには常にバイトインデックス・行番号・列番号を含める。
 */
class YamlParseException: Exception
{
	///
	this(string msg, size_t index, size_t line, size_t col,
		string file = __FILE__, size_t srcLine = __LINE__) @safe
	{
		super(format("%s at index %d (line=%d, column=%d)", msg, index, line, col), file, srcLine);
	}
}

/*******************************************************************************
 * YAML Builder
 * 
 * `allocator` に `mixin template` を指定することで、メモリ確保方式を差し替え可能。
 * 既定は `YamlDefaultAllocator`（GCベース）。
 */
struct YamlBuilderImpl(alias allocator = YamlDefaultAllocator)
{
private:
	mixin allocator!();
	///
	alias YamlBuilder = YamlBuilderImpl;
public:
	// ==========================================================================
	// MARK: - - Builder Types
	// ==========================================================================
	///
	alias YamlValue = .YamlValueImpl!YamlBuilder;
	///
	alias YamlType = YamlValue.Type;
	/// ditto
	alias YamlKey = YamlValue.YamlKey;
	/// ditto
	alias YamlString = YamlValue.YamlString;
	/// ditto
	alias YamlInteger = YamlValue.YamlInteger;
	/// ditto
	alias YamlUInteger = YamlValue.YamlUInteger;
	/// ditto
	alias YamlBoolean = YamlValue.YamlBoolean;
	/// ditto
	alias YamlNullType = YamlValue.YamlNull;
	/// ditto
	alias YamlFloatingPoint = YamlValue.YamlFloatingPoint;
	/// ditto
	alias YamlMapping = YamlValue.YamlMapping;
	/// ditto
	alias YamlSequence = YamlValue.YamlSequence;
	/// ditto
	alias YamlAlias = YamlValue.YamlAlias;
	
private:
	// ==========================================================================
	// MARK: - - Builder Factory (internal helpers)
	// ==========================================================================
	// dispose()/copyStr()/copyComment() はいずれもライブラリ利用者が直接
	// 呼び出すことを想定しない内部ヘルパーのため private のまま据え置く。
	// make()/undefinedValue()/emptyArray()/emptyObject()/deepCopy()（値の
	// 構築を担う公開API）はこの下の public: セクションに実装する。
	
	/***************************************************************************
	 * Dispose the given YamlValue
	 * 
	 * 既定のGCアロケータではno-op。アロケータ差し替え時にリソース解放フックとして使う。
	 */
	void dispose(ref YamlValue v) pure nothrow @nogc @safe
	{
		cast(void)v;
	}
	
	/***************************************************************************
	 * `String`の複製を作る
	 * 
	 * 既定のアロケータでは単なるキャストであり、実際のバッファ複製は行わない
	 * （D文字列は不変であり、複数の`String`が同じバッファを指しても安全なため）。
	 * カスタムアロケータ（プーリング等）に差し替えた場合に実体の複製フックとして
	 * 使えるよう用意している。
	 */
	auto copyStr()(in String str) @safe => cast(String)str[];
	
	/***************************************************************************
	 * コメント1件の複製を作る（`_comments`配列の複製時に使用）
	 */
	YamlValue.Comment copyComment()(in YamlValue.Comment c) @safe
	{
		return c.match!(
			(ref const(YamlValue.LineComment) lc) => YamlValue.Comment(YamlValue.LineComment(copyStr(lc.value))),
			(ref const(YamlValue.TrailingComment) tc) => YamlValue.Comment(YamlValue.TrailingComment(copyStr(tc.value))));
	}
	
public:
	// ==========================================================================
	// MARK: - - Builder Factory
	// ==========================================================================
	// 値の組み立て（構築）に対応する公開API群。
	
	/***************************************************************************
	 * 与えられた値からYamlValueを構築する
	 * 
	 * 対応する型は`YamlValueImpl.opAssign`が受理するもの全て（文字列・整数・
	 * 浮動小数点・真偽値・null・配列・連想配列・各`Yaml*`構造体そのもの）。
	 * Params:
	 *      v = 構築元の値
	 * Returns:
	 *      構築された`YamlValue`
	 */
	YamlValue make(T)(T v) @trusted
	{
		return YamlValue(v, this);
	}
	
	/***************************************************************************
	 * 未定義値（`YamlType.undefined`）を作成する
	 * 
	 * マッピングのエントリにこの値を割り当てると、そのエントリはstringify時に
	 * 出力されない。
	 */
	YamlValue undefinedValue() pure nothrow @trusted
	{
		return YamlValue(this);
	}
	
	/***************************************************************************
	 * 空のシーケンスを作成する（block styleが既定）
	 */
	YamlValue emptyArray() pure nothrow @trusted
	{
		return YamlValue(YamlValue.YamlSequence.init, this);
	}
	
	/***************************************************************************
	 * 空のマッピングを作成する（block styleが既定）
	 */
	YamlValue emptyObject() pure nothrow @trusted
	{
		return YamlValue(YamlValue.YamlMapping.init, this);
	}
	
	/***************************************************************************
	 * ノードの深いコピーを作成する
	 * 
	 * コレクション（YamlSequence/YamlMapping）は内部の`Array`/`Dictionary`を
	 * 新規に確保し直し、各要素を再帰的に複製する。スカラーの`String`フィールドは
	 * `copyStr()`経由（既定アロケータでは単なるキャスト）で複製したことにする。
	 * `_comments`・`_anchor`・`_tag`も複製対象に含める。`YamlAlias`の場合は
	 * `resolved`もヒープに再確保し、再帰的に複製することで元のエイリアス連鎖と
	 * 完全に独立させる。
	 * 
	 * 戻り値の`_builder`は複製元のものではなく、本メソッドを呼び出した
	 * builder自身（`this`）に設定される（`YamlValueImpl(value, this)`
	 * コンストラクタを使う方式）。
	 */
	YamlValue deepCopy(in YamlValue src) pure nothrow @trusted
	{
		auto ret = src._instance.match!(
			(ref const(YamlValue.YamlSequence) seq)
			{
				auto newAry = allocAry!YamlValue;
				foreach (ref e; seq.value[])
					newAry ~= deepCopy(e);
				auto newSeq = YamlValue.YamlSequence(newAry, seq.style, seq.trailingComma, seq.singleLine);
				foreach (ref c; seq.trailingComments[])
					newSeq.trailingComments ~= copyComment(c);
				return YamlValue(newSeq, this);
			},
			(ref const(YamlValue.YamlMapping) map)
			{
				auto newDic = allocDic!(YamlValue.YamlKey, YamlValue);
				foreach (ref item; map.value.byKeyValue)
				{
					auto newKey = YamlValue.YamlKey(copyStr(item.key.value), item.key.style);
					newDic.append(newKey, deepCopy(item.value));
				}
				auto newMap = YamlValue.YamlMapping(newDic, map.style, map.trailingComma, map.singleLine);
				foreach (ref c; map.trailingComments[])
					newMap.trailingComments ~= copyComment(c);
				return YamlValue(newMap, this);
			},
			(ref const(YamlValue.YamlString) str) => YamlValue(YamlValue.YamlString(
				copyStr(str.value), str.style, copyStr(str.raw), str.chomping, str.explicitIndent), this),
			(ref const(YamlValue.YamlInteger) num) => YamlValue(YamlValue.YamlInteger(
				num.value, num.positiveSign, num.base, copyStr(num.raw)), this),
			(ref const(YamlValue.YamlUInteger) num) => YamlValue(YamlValue.YamlUInteger(
				num.value, num.positiveSign, num.base, copyStr(num.raw)), this),
			(ref const(YamlValue.YamlFloatingPoint) num) => YamlValue(YamlValue.YamlFloatingPoint(
				num.value, num.leadingDecimalPoint, num.tailingDecimalPoint,
				num.positiveSign, num.withExponent, num.precision, copyStr(num.raw)), this),
			(ref const(YamlValue.YamlBoolean) b) => YamlValue(
				YamlValue.YamlBoolean(b.value, copyStr(b.raw)), this),
			(ref const(YamlValue.YamlNull) n) => YamlValue(
				YamlValue.YamlNull(copyStr(n.raw)), this),
			(ref const(YamlValue.YamlAlias) al)
			{
				auto resolvedCopy = new YamlValue;
				*resolvedCopy = deepCopy(*al.resolved);
				return YamlValue(YamlValue.YamlAlias(copyStr(al.value), resolvedCopy), this);
			},
			(ref const(YamlValue.UndefinedValue) _) => undefinedValue());
		ret._comments = allocAry!(YamlValue.Comment);
		foreach (ref c; src._comments[])
			ret._comments ~= copyComment(c);
		if (!src._anchor.isNull)
			ret._anchor = nullable(copyStr(src._anchor.get));
		if (!src._tag.isNull)
			ret._tag = nullable(copyStr(src._tag.get));
		return ret;
	}
	///
	@safe unittest
	{
		auto builder = YamlBuilder();
		
		// make(): D言語の値からYamlValueを構築する
		auto num = builder.make(42);
		assert(num.asInteger.value == 42);
		
		// emptyArray()/emptyObject(): 空のコレクションを作り、後から要素を追加する
		auto seq = builder.emptyArray();
		seq.asSequence.value ~= builder.make(1);
		seq.asSequence.value ~= builder.make(2);
		assert(seq.asSequence.value.length == 2);
		
		auto obj = builder.emptyObject();
		obj.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlValue.String)"name"), builder.make("Alice"));
		assert(obj.asMapping["name"].asString.value[] == "Alice");
		
		// deepCopy(): 複製先を変更しても複製元には影響しない独立したコピーを作る
		auto copied = builder.deepCopy(seq);
		copied.asSequence.value ~= builder.make(3);
		assert(seq.asSequence.value.length == 2);
		assert(copied.asSequence.value.length == 3);
		
		// undefinedValue(): マッピングのエントリに割り当てるとstringify時に
		// そのエントリごと出力されない
		auto obj2 = builder.emptyObject();
		obj2.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlValue.String)"visible"), builder.make(1));
		obj2.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlValue.String)"hidden"), builder.undefinedValue());
		auto app = appender!(char[])();
		builder.toPrettyString(app, obj2);
		assert(app.data == "visible: 1\n");
	}
	
private:
	// ==========================================================================
	// MARK: - - Parser
	// ==========================================================================
	// 字句解析共通部品（インデント管理・行列カウンタ・改行コード処理・タブ禁止検査）
	
	/***************************************************************************
	 * UTF-8 BOM（`\uFEFF`）をスキップする
	 * 
	 * ストリーム先頭でのみ呼び出すこと。それ以外の位置にBOMが
	 * 出現した場合の扱いは呼び出し側（`parse()`）の責務とする。
	 * Params:
	 *      src = 判定対象の文字列（通常はストリーム先頭）
	 * Returns:
	 *      BOMが存在した場合は消費したバイト数（3）、存在しなければ0
	 */
	size_t skipBOMImpl(in char[] src) const pure nothrow @nogc @safe
	{
		enum bom = "\uFEFF";
		if (src.length >= bom.length && src[0 .. bom.length] == bom)
			return bom.length;
		return 0;
	}
	
	/***************************************************************************
	 * 改行シーケンス（`\n` / `\r\n` / `\r`）を1つ消費し、line/colを更新する
	 * 
	 * `\n`・`\r\n`・`\r` はいずれも1回の改行として正規化して扱う
	 * （出力時は既定で`\n`に統一される）。
	 * Params:
	 *      src  = 現在位置からの残り文字列
	 *      line = 行番号（改行を検出した場合にインクリメントする）
	 *      col  = 列番号（改行を検出した場合に1にリセットする）
	 * Returns:
	 *      消費した文字数（先頭が改行でなければ0）
	 */
	size_t skipNewlineImpl(in char[] src, ref size_t line, ref size_t col) const pure nothrow @nogc @safe
	{
		if (src.length == 0)
			return 0;
		if (src[0] == '\n')
		{
			line++;
			col = 1;
			return 1;
		}
		if (src[0] == '\r')
		{
			line++;
			col = 1;
			if (src.length >= 2 && src[1] == '\n')
				return 2;
			return 1;
		}
		return 0;
	}
	
	/***************************************************************************
	 * 行頭からのインデント量（半角スペースの個数）を計測する
	 * 
	 * 非空白文字、改行文字、または文字列末尾に到達した時点で計測を終える。
	 * インデント中にタブ文字が1つでも混入していた場合は `YamlParseException` を
	 * 送出する（YAML仕様上、インデントへのタブ使用は禁止されている）。
	 * Params:
	 *      src  = 行頭からの文字列（行頭であることは呼び出し側が保証する）
	 *      line = エラーメッセージ用の行番号
	 *      col  = 列番号（消費したスペースの数だけ加算される）
	 * Returns:
	 *      インデント量（消費した半角スペース文字数と一致する）
	 * Throws:
	 *      インデント領域にタブ文字が含まれる場合 `YamlParseException`
	 */
	size_t measureIndentImpl(in char[] src, size_t line, ref size_t col) const @safe
	{
		size_t i;
		while (i < src.length)
		{
			if (src[i] == ' ')
			{
				i++;
				col++;
				continue;
			}
			if (src[i] == '\t')
			{
				throw new YamlParseException(
					"Tab character is not allowed for indentation", i, line, col);
			}
			break;
		}
		return i;
	}
	
	// plainスカラーパーサ（終端判定ロジック含む）
	
	/***************************************************************************
	 * 現在位置がplainスカラーの終端であるかどうかを判定する
	 * 
	 * 以下をすべて終端条件として判定する:
	 * - 文字列末尾（EOF）
	 * - `:` の直後が空白・タブ・改行・EOFである場合（マッピングのキー/値区切り）
	 * - フロー文脈で `:` の直後が `,`/`]`/`}` である場合
	 * - フロー文脈での `,`/`]`/`}` そのもの
	 * - 改行文字そのもの（複数行の折り畳み判定は呼び出し側 `parsePlainScalarImpl` が行う）
	 * - 空白（またはタブ）の連続の後に コメント開始(`#`)・改行・EOFが続く場合
	 *   （行末の余分な空白はスカラーに含めない）
	 * 
	 * この関数は「ここでスカラーの走査を止めるべきか」だけを判定する。
	 * plainスカラーとして開始してよい位置かどうか（先頭がインジケータ文字でないか等）の
	 * 判定は呼び出し側（ブロック/フローコレクションパーサ）の責務であり、
	 * この関数のスコープ外とする。
	 * Params:
	 *      rest          = 現在位置からの残り文字列
	 *      inFlowContext = フローコレクション（`[...]`/`{...}`）内かどうか
	 * Returns:
	 *      終端位置であれば true
	 */
	bool isPlainScalarTerminator(in char[] rest, bool inFlowContext) const pure nothrow @nogc @safe
	{
		if (rest.length == 0)
			return true;
		if (rest[0] == ':')
		{
			if (rest.length == 1)
				return true;
			if (rest[1] == ' ' || rest[1] == '\t' || rest[1] == '\n' || rest[1] == '\r')
				return true;
			if (inFlowContext && (rest[1] == ',' || rest[1] == ']' || rest[1] == '}'))
				return true;
		}
		if (inFlowContext && (rest[0] == ',' || rest[0] == ']' || rest[0] == '}'))
			return true;
		if (rest[0] == '\n' || rest[0] == '\r')
			return true;
		if (rest[0] == ' ' || rest[0] == '\t')
		{
			size_t j;
			while (j < rest.length && (rest[j] == ' ' || rest[j] == '\t'))
				j++;
			if (j == rest.length)
				return true;
			if (rest[j] == '#')
				return true;
			if (rest[j] == '\n' || rest[j] == '\r')
				return true;
		}
		return false;
	}
	
	/***************************************************************************
	 * plainスカラー（クォートなし文字列）をパースする
	 * 
	 * 複数行にまたがる場合、改行（および間の空行）は半角スペース1つに
	 * 折り畳む。継続行のインデントが `minIndent` 未満の
	 * 場合はそこでスカラーを終了する（改行自体は消費しない）。
	 * Params:
	 *      dst           = パース結果の格納先
	 *      src           = 現在位置からの文字列（plainスカラーの開始位置であることは
	 *                      呼び出し側が保証する。すなわち `isPlainScalarTerminator`
	 *                      が false を返す位置であること）
	 *      line          = 行番号（改行のたびに更新される）
	 *      col           = 列番号（消費した文字数だけ更新される）
	 *      minIndent     = 継続行として認める最小インデント量
	 *      inFlowContext = フローコレクション内かどうか
	 * Returns:
	 *      消費した文字数
	 */
	size_t parsePlainScalarImpl(ref YamlValue.YamlString dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent, bool inFlowContext) @safe
	{
		assert(src.length > 0, "Empty source for plain scalar");
		assert(!isPlainScalarTerminator(src, inFlowContext),
			"Cannot start plain scalar at a terminator position");
		
		size_t i;
		auto content = allocStr();
		
		while (true)
		{
			auto rest = src[i .. $];
			if (rest.length == 0)
				break;
			if (rest[0] == '\n' || rest[0] == '\r')
			{
				size_t j;
				size_t peekLine = line;
				size_t peekCol  = col;
				bool   foundContinuation;
				
				while (true)
				{
					size_t nlLen = skipNewlineImpl(rest[j .. $], peekLine, peekCol);
					assert(nlLen > 0, "Expected a newline sequence");
					j += nlLen;
					size_t indentCol = peekCol;
					size_t indentLen = measureIndentImpl(rest[j .. $], peekLine, indentCol);
					auto afterIndent = rest[j + indentLen .. $];
					if (afterIndent.length == 0)
						break;
					if (afterIndent[0] == '\n' || afterIndent[0] == '\r')
					{
						// 空行: 消費して次の行を見に行く
						j += indentLen;
						peekCol = indentCol;
						continue;
					}
					if (afterIndent[0] == '#')
					{
						// コメント行はスカラーの継続とはみなさない。この行を
						// 消費せずに折り畳み探索を打ち切り、スカラーをここで
						// 終了させる。コメント自体は後でその位置から
						// `skipBlankAndCommentLinesImpl`等が改めて読み取り、
						// 次の実トークンのleading commentとして蓄積する。
						break;
					}
					if (isPlainScalarTerminator(afterIndent, inFlowContext))
					{
						// 継続行の内容が即座にスカラー終端（フロー終端記号`]`/`}`/`,`や
						// `: `等）である場合は、継続とはみなさずここでスカラーを
						// 終了させる。この判定を怠ると、後続の
						// `content ~= ' ';` によって改行が誤ってスペース1つに
						// 折り畳まれてしまい、内容の末尾に余分な空白が残ってしまう
						// （flow文脈で要素の直後に改行を挟んで
						// `]`/`,`が続く場合に顕在化する）。
						break;
					}
					if (indentLen < minIndent)
						break;
					j += indentLen;
					peekCol = indentCol;
					foundContinuation = true;
					break;
				}
				
				if (!foundContinuation)
					break;
				
				// 改行(+空行)をスペース1つに折り畳む
				content ~= ' ';
				i += j;
				line = peekLine;
				col  = peekCol;
				continue;
			}
			if (rest[0] == ' ' || rest[0] == '\t')
			{
				// 行末の空白かどうかを判定する（コメント/改行/EOFが続くか）。
				// 行末空白であれば内容には含めず読み飛ばすだけに留め、
				// 改行の場合は次周でループ先頭の折り畳み判定に委ねる
				// （ここで即座にbreakしてしまうと、後続行への折り畳みが
				// 判定できなくなってしまうため）。
				size_t j;
				while (j < rest.length && (rest[j] == ' ' || rest[j] == '\t'))
					j++;
				if (j == rest.length)
					break; // 末尾空白の後にEOF
				if (rest[j] == '#')
					break; // 末尾空白の後にコメント
				if (rest[j] == '\n' || rest[j] == '\r')
				{
					// 末尾空白の後に改行: 空白は捨てて改行位置まで読み飛ばす
					i   += j;
					col += j;
					continue;
				}
				// 末尾ではない空白（語の区切り）は通常の内容として消費
				content ~= rest[0];
				i++;
				col++;
				continue;
			}
			if (isPlainScalarTerminator(rest, inFlowContext))
				break;
			content ~= rest[0];
			i++;
			col++;
		}
		
		dst = YamlValue.YamlString(content);
		return i;
	}
	
	// quoted文字列パーサ（single/double、エスケープ規則）
	
	/***************************************************************************
	 * 改行（および間の空行）を読み飛ばし、半角スペース1つに畳み込む位置まで進める
	 * 
	 * single/doubleクォート文字列の複数行対応で共通して使う補助関数。plainスカラーの
	 * `parsePlainScalarImpl` と異なり、継続行のインデント量による終端判定は行わない
	 * （quoted文字列は閉じクォートまで明示的に区切られているため、途中でインデントが
	 * 浅くなっても単に読み飛ばして継続する）。
	 * Params:
	 *      rest = 改行文字から始まる残り文字列（`rest[0]` が `\n` または `\r` であること）
	 *      line = 行番号（更新される）
	 *      col  = 列番号（更新される、消費した改行・インデント分だけ進む）
	 * Returns:
	 *      消費した文字数
	 */
	size_t skipFoldedNewlineImpl(in char[] rest, ref size_t line, ref size_t col) @safe
	{
		size_t j;
		while (true)
		{
			size_t nlLen = skipNewlineImpl(rest[j .. $], line, col);
			assert(nlLen > 0, "Expected a newline sequence");
			j += nlLen;
			size_t indentCol = col;
			size_t indentLen = measureIndentImpl(rest[j .. $], line, indentCol);
			auto afterIndent = rest[j + indentLen .. $];
			if (afterIndent.length > 0 && (afterIndent[0] == '\n' || afterIndent[0] == '\r'))
			{
				// 空行: 消費して次の行へ
				j += indentLen;
				col = indentCol;
				continue;
			}
			j += indentLen;
			col = indentCol;
			break;
		}
		return j;
	}
	
	/***************************************************************************
	 * 16進エスケープシーケンスの桁部分を読み取り、コードポイントに変換する
	 * Params:
	 *      digits     = 16進数字部分の文字列（先頭`digitCount`文字を読む）
	 *      digitCount = 桁数（`\x`=2、`\u`=4、`\U`=8）
	 *      index      = エラーメッセージ用のバイトインデックス
	 *      line       = エラーメッセージ用の行番号
	 *      col        = エラーメッセージ用の列番号
	 * Returns:
	 *      変換されたUnicodeコードポイント
	 * Throws:
	 *      桁数が不足している、または16進数字以外の文字が含まれる場合 `YamlParseException`
	 */
	dchar parseHexEscapeImpl(in char[] digits, size_t digitCount,
		size_t index, size_t line, size_t col) const @safe
	{
		if (digits.length < digitCount)
		{
			throw new YamlParseException(
				"Incomplete hex escape sequence", index, line, col);
		}
		uint value;
		foreach (k; 0 .. digitCount)
		{
			immutable c = digits[k];
			uint digit;
			if (c >= '0' && c <= '9')
				digit = c - '0';
			else if (c >= 'a' && c <= 'f')
				digit = c - 'a' + 10;
			else if (c >= 'A' && c <= 'F')
				digit = c - 'A' + 10;
			else
			{
				throw new YamlParseException(
					"Invalid hex digit in escape sequence", index, line, col);
			}
			value = value * 16 + digit;
		}
		return cast(dchar)value;
	}
	
	/***************************************************************************
	 * シングルクォート文字列（`'...'`）をパースする
	 * 
	 * エスケープは `''`（2つの連続するシングルクォート）による1つのシングルクォート
	 * リテラルのみをサポートする（YAML仕様準拠、バックスラッシュは特別扱いしない）。
	 * 複数行にまたがる場合はplainスカラーと同様に改行（および間の空行）を
	 * 半角スペース1つに折り畳む。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`src[0]` が `'` であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = シグネチャ統一のために受け取るが、quoted文字列は明示的な
	 *                  閉じクォートで区切られるため終端判定には使用しない
	 *                  （plainスカラーとの意図的な扱いの違い）
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      閉じクォートに到達せずEOFに達した場合 `YamlParseException`
	 */
	size_t parseSingleQuotedImpl(ref YamlValue.YamlString dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		assert(src.length > 0 && src[0] == '\'', "Expected opening single quote");
		
		immutable startLine = line;
		immutable startCol  = col;
		size_t i = 1;
		col++;
		auto content = allocStr();
		
		while (true)
		{
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated single-quoted string", i, startLine, startCol);
			}
			auto rest = src[i .. $];
			if (rest[0] == '\'')
			{
				if (rest.length >= 2 && rest[1] == '\'')
				{
					content ~= '\'';
					i += 2;
					col += 2;
					continue;
				}
				i += 1;
				col += 1;
				break;
			}
			if (rest[0] == '\n' || rest[0] == '\r')
			{
				immutable consumed = skipFoldedNewlineImpl(rest, line, col);
				content ~= ' ';
				i += consumed;
				continue;
			}
			content ~= rest[0];
			i++;
			col++;
		}
		
		dst = YamlValue.YamlString(content);
		dst.style = ScalarStyle.singleQuoted;
		return i;
	}
	
	/***************************************************************************
	 * ダブルクォート文字列（`"..."`）をパースする
	 * 
	 * YAML仕様のエスケープシーケンスをサポートする:
	 * `\0 \a \b \t \n \v \f \r \e \" \\ \/ \  \N \_ \L \P` の名前付きエスケープ、
	 * `\xXX`（8bit）・`\uXXXX`（16bit）・`\UXXXXXXXX`（32bit）の16進エスケープ、
	 * および `\` の直後に改行が続く場合の行継続（改行そのものを取り除き、
	 * 折り畳みスペースも挿入しない）。エスケープを伴わない改行は
	 * シングルクォート文字列と同様に半角スペース1つへ折り畳む。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`src[0]` が `"` であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = シグネチャ統一のために受け取るが、quoted文字列は明示的な
	 *                  閉じクォートで区切られるため終端判定には使用しない
	 *                  （plainスカラーとの意図的な扱いの違い）
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      閉じクォートに到達せずEOFに達した場合、または不正なエスケープシーケンスの場合
	 *      `YamlParseException`
	 */
	size_t parseDoubleQuotedImpl(ref YamlValue.YamlString dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		assert(src.length > 0 && src[0] == '"', "Expected opening double quote");
		
		immutable startLine = line;
		immutable startCol  = col;
		size_t i = 1;
		col++;
		auto content = allocStr();
		
		while (true)
		{
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated double-quoted string", i, startLine, startCol);
			}
			auto rest = src[i .. $];
			if (rest[0] == '"')
			{
				i += 1;
				col += 1;
				break;
			}
			if (rest[0] == '\\')
			{
				if (rest.length < 2)
				{
					throw new YamlParseException(
						"Unterminated escape sequence", i, line, col);
				}
				if (rest[1] == '\n' || rest[1] == '\r')
				{
					// 行継続: バックスラッシュ+改行を取り除き、折り畳みスペースは挿入しない
					immutable nlLen = skipNewlineImpl(rest[1 .. $], line, col);
					i += 1 + nlLen;
					immutable indentCol = col;
					size_t indentColMut = indentCol;
					immutable indentLen = measureIndentImpl(src[i .. $], line, indentColMut);
					i += indentLen;
					col = indentColMut;
					continue;
				}
				immutable c = rest[1];
				switch (c)
				{
				case '0':  content ~= '\0'; i += 2; col += 2; break;
				case 'a':  content ~= '\a'; i += 2; col += 2; break;
				case 'b':  content ~= '\b'; i += 2; col += 2; break;
				case 't':  content ~= '\t'; i += 2; col += 2; break;
				case 'n':  content ~= '\n'; i += 2; col += 2; break;
				case 'v':  content ~= '\v'; i += 2; col += 2; break;
				case 'f':  content ~= '\f'; i += 2; col += 2; break;
				case 'r':  content ~= '\r'; i += 2; col += 2; break;
				case 'e':  content ~= cast(char)0x1B; i += 2; col += 2; break;
				case ' ':  content ~= ' ';  i += 2; col += 2; break;
				case '"':  content ~= '"';  i += 2; col += 2; break;
				case '/':  content ~= '/';  i += 2; col += 2; break;
				case '\\': content ~= '\\'; i += 2; col += 2; break;
				case 'N':
					{
						char[4] buf;
						immutable len = encode(buf, cast(dchar)0x0085);
						content ~= buf[0 .. len];
						i += 2; col += 2;
					}
					break;
				case '_':
					{
						char[4] buf;
						immutable len = encode(buf, cast(dchar)0x00A0);
						content ~= buf[0 .. len];
						i += 2; col += 2;
					}
					break;
				case 'L':
					{
						char[4] buf;
						immutable len = encode(buf, cast(dchar)0x2028);
						content ~= buf[0 .. len];
						i += 2; col += 2;
					}
					break;
				case 'P':
					{
						char[4] buf;
						immutable len = encode(buf, cast(dchar)0x2029);
						content ~= buf[0 .. len];
						i += 2; col += 2;
					}
					break;
				case 'x':
					{
						immutable cp = parseHexEscapeImpl(rest[2 .. $], 2, i, line, col);
						char[4] buf;
						immutable len = encode(buf, cp);
						content ~= buf[0 .. len];
						i += 2 + 2; col += 2 + 2;
					}
					break;
				case 'u':
					{
						immutable cp = parseHexEscapeImpl(rest[2 .. $], 4, i, line, col);
						char[4] buf;
						immutable len = encode(buf, cp);
						content ~= buf[0 .. len];
						i += 2 + 4; col += 2 + 4;
					}
					break;
				case 'U':
					{
						immutable cp = parseHexEscapeImpl(rest[2 .. $], 8, i, line, col);
						char[4] buf;
						immutable len = encode(buf, cp);
						content ~= buf[0 .. len];
						i += 2 + 8; col += 2 + 8;
					}
					break;
				default:
					throw new YamlParseException(
						format("Invalid escape sequence '\\%s'", c), i, line, col);
				}
				continue;
			}
			if (rest[0] == '\n' || rest[0] == '\r')
			{
				immutable consumed = skipFoldedNewlineImpl(rest, line, col);
				content ~= ' ';
				i += consumed;
				continue;
			}
			content ~= rest[0];
			i++;
			col++;
		}
		
		dst = YamlValue.YamlString(content);
		dst.style = ScalarStyle.doubleQuoted;
		return i;
	}
	
	// ブロックスカラーパーサ（literal/folded、chomping、明示インデント）
	
	/***************************************************************************
	 * chomping指定子に応じて、末尾の改行を刈り込む
	 * 
	 * - `strip`: 末尾の改行をすべて除去する
	 * - `clip`（既定）: 末尾の改行を1つだけ残す（1つも無ければ何もしない）
	 * - `keep`: 何もしない（末尾の改行をすべて残す）
	 * Params:
	 *      raw      = 刈り込み前の文字列（自然な末尾改行を含む）
	 *      chomping = chomping指定子
	 * Returns:
	 *      刈り込み後の文字列（`raw`のスライス。コピーは発生しない）
	 */
	String applyChompingImpl(String raw, ChompingIndicator chomping) const pure nothrow @nogc @safe
	{
		size_t trailingNlCount;
		while (trailingNlCount < raw.length && raw[$ - 1 - trailingNlCount] == '\n')
			trailingNlCount++;
		final switch (chomping)
		{
		case ChompingIndicator.strip:
			return cast(String)(raw[0 .. $ - trailingNlCount]);
		case ChompingIndicator.clip:
			if (trailingNlCount > 1)
				return cast(String)(raw[0 .. $ - (trailingNlCount - 1)]);
			return raw;
		case ChompingIndicator.keep:
			return raw;
		}
	}
	
	/***************************************************************************
	 * ブロックスカラー（literal `|` / folded `>`）をパースする
	 * 
	 * ヘッダ行（`|`/`>` + 任意の明示インデント指定子(1桁の数字) + 任意のchomping
	 * 指定子(`-`/`+`、順序は問わない) + 任意のコメント）を解析した後、本文行を
	 * 収集する。ブロックの基準インデントは、明示インデント指定子があれば
	 * `minIndent + 指定値`、無ければ最初の非空行のインデント量から自動検出する。
	 * 
	 * 内容の組み立て:
	 * - literalスタイル: 各行を改行でそのまま連結する（空行もそのまま改行として残る）。
	 * - foldedスタイル: 連続する2つの非空行の間の単一の改行は半角スペースに変換する。
	 *   間に空行が挟まる場合はその空行の数だけ改行として残す
	 *   （YAML仕様が定める「より深くインデントされた行は折り畳まない」という
	 *   例外は本実装では簡略化のため区別しない）。
	 * 
	 * 組み立てた内容に対して、最後に `applyChompingImpl` でchompingを適用する。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`src[0]` が `|` または `>` であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 明示インデント指定子の基準となる親のインデント量
	 * Returns:
	 *      消費した文字数
	 */
	size_t parseBlockScalarImpl(ref YamlValue.YamlString dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		assert(src.length > 0 && (src[0] == '|' || src[0] == '>'),
			"Expected block scalar indicator");
		
		immutable isLiteral = (src[0] == '|');
		size_t i = 1;
		col++;
		
		// ヘッダ: 明示インデント指定子とchomping指定子を任意の順序で最大1つずつ許可
		Nullable!ubyte explicitIndent;
		auto chomping = ChompingIndicator.clip;
		
		foreach (_; 0 .. 2)
		{
			if (i >= src.length)
				break;
			immutable hc = src[i];
			if (hc >= '1' && hc <= '9' && explicitIndent.isNull)
			{
				explicitIndent = nullable(cast(ubyte)(hc - '0'));
				i++;
				col++;
			}
			else if (hc == '-' || hc == '+')
			{
				chomping = (hc == '-') ? ChompingIndicator.strip : ChompingIndicator.keep;
				i++;
				col++;
			}
			else
			{
				break;
			}
		}
		
		// ヘッダ行の残り（空白・コメント）を読み飛ばし、改行を消費する
		while (i < src.length && (src[i] == ' ' || src[i] == '\t'))
		{
			i++;
			col++;
		}
		if (i < src.length && src[i] == '#')
		{
			while (i < src.length && src[i] != '\n' && src[i] != '\r')
			{
				i++;
				col++;
			}
		}
		if (i < src.length && (src[i] == '\n' || src[i] == '\r'))
		{
			immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
			i += nlLen;
		}
		
		Nullable!size_t baseIndent;
		if (!explicitIndent.isNull)
			baseIndent = nullable(minIndent + explicitIndent.get);
		
		string[] lines;
		
		while (true)
		{
			if (i >= src.length)
				break;
			auto lineStart = src[i .. $];
			immutable lineStartCol = col;
			size_t indentCol = col;
			immutable indentLen = measureIndentImpl(lineStart, line, indentCol);
			auto afterIndent = lineStart[indentLen .. $];
			
			immutable isBlank = afterIndent.length == 0
				|| afterIndent[0] == '\n' || afterIndent[0] == '\r';
			
			if (isBlank)
			{
				lines ~= "";
				i += indentLen;
				col = indentCol;
				if (i < src.length && (src[i] == '\n' || src[i] == '\r'))
				{
					immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
					i += nlLen;
					continue;
				}
				break; // 改行なしでEOFに到達
			}
			
			if (baseIndent.isNull)
			{
				if (indentLen <= minIndent)
					break; // 内容行が1つもない（空のブロックスカラー）
				baseIndent = nullable(size_t(indentLen));
			}
			
			if (indentLen < baseIndent.get)
				break; // インデント不足: この行は消費せずブロックスカラーを終了
			
			immutable skip = baseIndent.get;
			auto contentPart = lineStart[skip .. $];
			size_t lineLen;
			while (lineLen < contentPart.length
				&& contentPart[lineLen] != '\n' && contentPart[lineLen] != '\r')
			{
				lineLen++;
			}
			lines ~= contentPart[0 .. lineLen].idup;
			i += skip + lineLen;
			col = lineStartCol + skip + lineLen;
			
			if (i < src.length && (src[i] == '\n' || src[i] == '\r'))
			{
				immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
				i += nlLen;
				continue;
			}
			break; // 改行なしでEOFに到達
		}
		
		auto content = allocStr();
		if (isLiteral)
		{
			foreach (ln; lines)
			{
				content ~= ln;
				content ~= '\n';
			}
		}
		else
		{
			size_t blanksPending;
			bool anyContentYet;
			foreach (ln; lines)
			{
				if (ln.length == 0)
				{
					blanksPending++;
					continue;
				}
				if (anyContentYet)
				{
					if (blanksPending == 0)
					{
						content ~= ' ';
					}
					else
					{
						foreach (_; 0 .. blanksPending)
							content ~= '\n';
					}
				}
				content ~= ln;
				anyContentYet = true;
				blanksPending = 0;
			}
			if (anyContentYet)
				content ~= '\n';
			foreach (_; 0 .. blanksPending)
				content ~= '\n';
		}
		
		dst = YamlValue.YamlString(applyChompingImpl(content, chomping));
		dst.style          = isLiteral ? ScalarStyle.literal : ScalarStyle.folded;
		dst.chomping        = chomping;
		dst.explicitIndent  = explicitIndent;
		return i;
	}
	
	// スカラー型解決ロジック（resolveScalarType、暗黙null含む）
	
	/***************************************************************************
	 * 与えられた文字列がすべて8進数字（0〜7）で構成されているかどうかを判定する
	 */
	bool isAllOctalDigitsImpl(in char[] s) const pure nothrow @nogc @safe
	{
		if (s.length == 0)
			return false;
		foreach (c; s)
		{
			if (!isOctalDigit(c))
				return false;
		}
		return true;
	}
	
	/***************************************************************************
	 * plainスカラーの生テキストから実際の型を解決する
	 * 
	 * YAML 1.2 Core Schema を既定とし、YAML 1.1 との互換性のため
	 * `yes/no/on/off`（真偽値）、8進数の伝統的表記（`0`始まりで`o`を伴わないもの）も
	 * 解決対象に含める。判定順序は
	 * `null候補 → bool候補 → 数値候補(10進/16進/8進/2進/浮動小数点) → それ以外は文字列`
	 * とする。
	 * 
	 * この関数は **plainスカラーの生テキストにのみ** 適用すること。quoted文字列や
	 * ブロックスカラーは明示的な区切り記法によって常に文字列型として確定するため、
	 * この関数を通す必要はない（呼び出し側の注意点）。
	 * 
	 * 解決された型の `raw` フィールドには常に元のテキストがそのまま保持される
	 * （stringify時に`raw`が優先して出力される）。数値以外にも到達できなかった場合は
	 * 文字列として扱う。
	 * Params:
	 *      dst = 解決結果の格納先
	 *      raw = plainスカラーの生テキスト（空文字列も許容し、暗黙のnullとして扱う）
	 * Returns:
	 *      解決された型
	 */
	YamlType resolveScalarTypeImpl(ref YamlValue dst, in char[] raw) @safe
	{
		// 空文字列: 暗黙のnull
		if (raw.length == 0)
		{
			auto n = YamlValue.YamlNull();
			n.raw = allocStr();
			dst = n;
			return YamlType.nullfied;
		}
		
		// null候補（1.2 Core Schema）
		if (raw == "~" || raw == "null" || raw == "Null" || raw == "NULL")
		{
			auto n = YamlValue.YamlNull();
			auto r = allocStr();
			r ~= raw;
			n.raw = r;
			dst = n;
			return YamlType.nullfied;
		}
		
		// bool候補（1.2 Core Schema + 1.1互換のyes/no/on/off）
		if (raw == "true" || raw == "True" || raw == "TRUE"
			|| raw == "yes" || raw == "Yes" || raw == "YES"
			|| raw == "on"  || raw == "On"  || raw == "ON")
		{
			auto r = allocStr();
			r ~= raw;
			dst = YamlValue.YamlBoolean(true, r);
			return YamlType.boolean;
		}
		if (raw == "false" || raw == "False" || raw == "FALSE"
			|| raw == "no"    || raw == "No"    || raw == "NO"
			|| raw == "off"   || raw == "Off"   || raw == "OFF")
		{
			auto r = allocStr();
			r ~= raw;
			dst = YamlValue.YamlBoolean(false, r);
			return YamlType.boolean;
		}
		
		// 数値候補: 符号を読み取る
		size_t index;
		immutable bool hasSign = raw[0] == '+' || raw[0] == '-';
		immutable bool positiveSign = raw.length > 0 && raw[0] == '+';
		immutable bool negative = raw.length > 0 && raw[0] == '-';
		if (hasSign)
			index++;
		auto body_ = raw[index .. $];
		
		// .inf / .Inf / .INF（符号可）
		if (body_ == ".inf" || body_ == ".Inf" || body_ == ".INF")
		{
			auto r = allocStr();
			r ~= raw;
			auto val = YamlValue.YamlFloatingPoint(
				negative ? -double.infinity : double.infinity);
			val.positiveSign = positiveSign;
			val.raw = r;
			dst = val;
			return YamlType.floating;
		}
		// .nan / .NaN / .NAN（符号なしのみ）
		if (!hasSign && (raw == ".nan" || raw == ".NaN" || raw == ".NAN"))
		{
			auto r = allocStr();
			r ~= raw;
			auto val = YamlValue.YamlFloatingPoint(double.nan);
			val.raw = r;
			dst = val;
			return YamlType.floating;
		}
		
		if (body_.length == 0)
			return resolveAsStringImpl(dst, raw);
		
		// 16進数: 0x / 0X
		if (body_.length > 2 && body_[0] == '0' && (body_[1] == 'x' || body_[1] == 'X'))
		{
			auto digits = body_[2 .. $];
			bool allHex = digits.length > 0;
			foreach (c; digits)
			{
				if (!isHexDigit(c))
				{
					allHex = false;
					break;
				}
			}
			if (allHex)
				return resolveIntegerImpl(dst, raw, digits, 16, positiveSign, negative, IntegerBase.hex);
		}
		// 2進数: 0b / 0B
		if (body_.length > 2 && body_[0] == '0' && (body_[1] == 'b' || body_[1] == 'B'))
		{
			auto digits = body_[2 .. $];
			bool allBin = digits.length > 0;
			foreach (c; digits)
			{
				if (c != '0' && c != '1')
				{
					allBin = false;
					break;
				}
			}
			if (allBin)
				return resolveIntegerImpl(dst, raw, digits, 2, positiveSign, negative, IntegerBase.binary);
		}
		// 8進数（1.2形式）: 0o / 0O
		if (body_.length > 2 && body_[0] == '0' && (body_[1] == 'o' || body_[1] == 'O'))
		{
			auto digits = body_[2 .. $];
			if (isAllOctalDigitsImpl(digits))
				return resolveIntegerImpl(dst, raw, digits, 8, positiveSign, negative, IntegerBase.octal);
		}
		// 8進数（1.1レガシー形式）: "0"で始まり、残り全体が8進数字のみ（長さ2以上）
		if (body_.length > 1 && body_[0] == '0' && isAllOctalDigitsImpl(body_[1 .. $]))
			return resolveIntegerImpl(dst, raw, body_[1 .. $], 8, positiveSign, negative, IntegerBase.octal);
		
		// 10進整数 / 浮動小数点数（手書き状態機械による判定）
		{
			size_t i;
			bool hasDecimal;
			bool hasExponent;
			bool leadingDecimal;
			bool trailingDecimal;
			size_t decimalPos;
			size_t precision;
			
			if (i < body_.length && body_[i] == '.')
				leadingDecimal = true;
			
			while (i < body_.length)
			{
				if (isDigit(body_[i]))
				{
					i++;
					if (hasDecimal)
						precision++;
				}
				else if (body_[i] == '.')
				{
					if (hasExponent || hasDecimal)
						return resolveAsStringImpl(dst, raw);
					hasDecimal = true;
					decimalPos = i;
					i++;
					precision = 0;
				}
				else if (body_[i] == 'e' || body_[i] == 'E')
				{
					if (hasExponent)
						return resolveAsStringImpl(dst, raw);
					hasExponent = true;
					i++;
					if (i < body_.length && (body_[i] == '+' || body_[i] == '-'))
						i++;
					immutable expDigitsStart = i;
					while (i < body_.length && isDigit(body_[i]))
						i++;
					if (i == expDigitsStart)
						return resolveAsStringImpl(dst, raw);
					trailingDecimal = false;
					if (hasDecimal)
					{
						precision = i - decimalPos - 1;
						if (hasExponent)
							precision = expDigitsStart - decimalPos - 1;
					}
					break;
				}
				else
				{
					// 数値として認識できない文字が残っている -> 文字列として扱う
					return resolveAsStringImpl(dst, raw);
				}
			}
			
			if (i == 0 || i != body_.length)
				return resolveAsStringImpl(dst, raw);
			
			trailingDecimal = trailingDecimal || (hasDecimal && !hasExponent && i == decimalPos + 1);
			
			auto numStr = body_[0 .. i];
			auto r = allocStr();
			r ~= raw;
			
			if (hasDecimal || hasExponent)
			{
				double value;
				try
					value = std.conv.parse!double(numStr);
				catch (ConvException)
					return resolveAsStringImpl(dst, raw);
				if (negative)
					value = -value;
				auto val = YamlValue.YamlFloatingPoint(value);
				val.leadingDecimalPoint = leadingDecimal;
				val.tailingDecimalPoint = trailingDecimal;
				val.withExponent        = hasExponent;
				val.precision           = precision;
				val.positiveSign        = positiveSign;
				val.raw = r;
				dst = val;
				return YamlType.floating;
			}
			return resolveIntegerImpl(dst, raw, numStr, 10, positiveSign, negative, IntegerBase.decimal);
		}
	}
	
	/***************************************************************************
	 * 数値文字列（符号・プレフィックス除去済み）を整数として解決する
	 * 
	 * `long` の範囲に収まる場合は符号の有無にかかわらず `YamlInteger`、
	 * 符号なしで `long.max` を超える場合のみ `YamlUInteger` とする。
	 * 桁溢れ等でパースに失敗した場合は数値としての解決を諦め、文字列として扱う。
	 */
	YamlType resolveIntegerImpl(ref YamlValue dst, in char[] raw, in char[] digits,
		uint base, bool positiveSign, bool negative, IntegerBase intBase) @safe
	{
		auto r = allocStr();
		r ~= raw;
		
		if (digits.length > 20)
			return resolveAsStringImpl(dst, raw);
		
		// 符号は別管理のため、常に符号なし桁として読み取ってから手動で符号を適用する
		// （`parse!long(s, radix)` は基数を明示指定すると符号付き文字列を扱えないため）
		ulong uvalue;
		try
		{
			auto s = digits.idup;
			uvalue = std.conv.parse!ulong(s, base);
		}
		catch (ConvException)
		{
			return resolveAsStringImpl(dst, raw);
		}
		
		if (negative)
		{
			enum ulong negLimit = cast(ulong)long.max + 1; // -long.min の絶対値
			if (uvalue > negLimit)
				return resolveAsStringImpl(dst, raw);
			immutable long value = (uvalue == negLimit) ? long.min : -cast(long)uvalue;
			auto val = YamlValue.YamlInteger(value);
			val.positiveSign = positiveSign;
			val.base = intBase;
			val.raw = r;
			dst = val;
			return YamlType.integer;
		}
		else
		{
			if (uvalue <= long.max)
			{
				auto val = YamlValue.YamlInteger(cast(long)uvalue);
				val.positiveSign = positiveSign;
				val.base = intBase;
				val.raw = r;
				dst = val;
				return YamlType.integer;
			}
			else
			{
				auto val = YamlValue.YamlUInteger(uvalue);
				val.positiveSign = positiveSign;
				val.base = intBase;
				val.raw = r;
				dst = val;
				return YamlType.uinteger;
			}
		}
	}
	
	/***************************************************************************
	 * どの数値・真偽値・null候補にも一致しなかった場合の文字列としての解決
	 * 
	 * `value`（実際の内容）と`raw`（stringify時に優先出力される元テキスト）の
	 * 両方に元のテキストを設定する。plainスカラーの文字列解決では両者は
	 * 常に一致する（数値等と異なり、値と表記が分離しないため）。
	 */
	YamlType resolveAsStringImpl(ref YamlValue dst, in char[] raw) @safe
	{
		auto v = allocStr();
		v ~= raw;
		auto r = allocStr();
		r ~= raw;
		auto val = YamlValue.YamlString(v);
		val.raw = r;
		dst = val;
		return YamlType.string;
	}
	
	// flowコレクションパーサ（`[...]`/`{...}`、ケツカンマ許容）
	
	/***************************************************************************
	 * flowコンテキスト内の区切り空白・改行を読み飛ばす
	 * 
	 * `[`/`{` の直後、`,` の前後、`]`/`}` の直前など、要素と要素の間の
	 * 構造的な区切りで使用する。plainスカラーの折り畳み（`parsePlainScalarImpl`）
	 * と異なり、ここで読み飛ばす空白・改行は内容ではなく区切りそのものであるため、
	 * スペース1つへの折り畳みは行わず単純に読み飛ばす。
	 * コメント（`#`）に遭遇した場合はその本文を`_pendingComments`に蓄積する。
	 * flow文脈のコメントはインデントに意味がないため、記録する
	 * `indentLen`は常に0とする（`attachAllPendingTrailingCommentsImpl`は
	 * インデント比較をしないため実際には参照されない）。要素自身と同一行で
	 * カンマの前に書かれたコメント（例: `[1 # comment\n, 2]`）も、そのカンマ直後の
	 * 次要素のleading commentとして扱う簡略化を採用している（同一行にあるため
	 * 本来はtrailing commentとする方が厳密だが、この記法は極めて稀であるため
	 * 実装の単純さを優先した）。
	 * Params:
	 *      src  = 現在位置からの文字列
	 *      line = 行番号（改行のたびに更新される）
	 *      col  = 列番号（消費した文字数だけ更新される）
	 * Returns:
	 *      消費した文字数
	 */
	size_t skipFlowSpacingImpl(in char[] src, ref size_t line, ref size_t col) @safe
	{
		size_t i;
		while (i < src.length)
		{
			if (src[i] == ' ' || src[i] == '\t')
			{
				i++;
				col++;
				continue;
			}
			if (src[i] == '#')
			{
				String text;
				immutable commentLen = parseCommentTextImpl(text, src[i .. $], col);
				_pendingComments ~= PendingComment(text, 0);
				i += commentLen;
				continue;
			}
			immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
			if (nlLen > 0)
			{
				i += nlLen;
				continue;
			}
			break;
		}
		return i;
	}
	
	/***************************************************************************
	 * flowノード（スカラーまたはネストしたflowコレクション）を1つパースする
	 * 
	 * 先頭文字により以下へ振り分ける:
	 * `[` → `parseFlowSequenceImpl` / `{` → `parseFlowMappingImpl` /
	 * `'` → `parseSingleQuotedImpl` / `"` → `parseDoubleQuotedImpl` /
	 * それ以外 → `parsePlainScalarImpl` の結果を `resolveScalarTypeImpl` で解決する。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（flowノードとして開始可能な位置であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 内部のplainスカラーが複数行に折り畳まれる際の最小インデント
	 *                  （呼び出し元のブロック文脈から引き継ぐ）
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      ノードとして開始できない位置（空要素を示す `,` に直接遭遇した場合等）は
	 *      `YamlParseException`
	 */
	size_t parseFlowNodeImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		attachPendingLeadingCommentsImpl(dst);
		
		if (src.length == 0)
		{
			throw new YamlParseException(
				"Unexpected end of input while expecting a flow node", 0, line, col);
		}
		if (src[0] == '&')
		{
			col++;
			String anchorName;
			immutable nameLen = parseAnchorNameImpl(anchorName, src[1 .. $], col);
			if (nameLen == 0)
				throw new YamlParseException("Anchor name must not be empty", 1, line, col);
			size_t afterName = 1 + nameLen;
			afterName += skipFlowSpacingImpl(src[afterName .. $], line, col);
			immutable valConsumed = parseFlowNodeImpl(dst, src[afterName .. $], line, col, minIndent);
			dst._anchor = nullable(anchorName);
			registerAnchorImpl(anchorName, dst);
			return afterName + valConsumed;
		}
		if (src[0] == '*')
		{
			col++;
			String aliasName;
			immutable nameLen = parseAnchorNameImpl(aliasName, src[1 .. $], col);
			if (nameLen == 0)
				throw new YamlParseException("Alias name must not be empty", 1, line, col);
			dst = resolveAliasImpl(aliasName, 1, line, col);
			return 1 + nameLen;
		}
		if (src[0] == '!')
		{
			String tagName;
			immutable tagLen = parseTagImpl(tagName, src, line, col);
			size_t afterTag = tagLen;
			afterTag += skipFlowSpacingImpl(src[afterTag .. $], line, col);
			immutable valConsumed = parseFlowNodeImpl(dst, src[afterTag .. $], line, col, minIndent);
			dst._tag = nullable(tagName);
			return afterTag + valConsumed;
		}
		if (src[0] == '[')
			return parseFlowSequenceImpl(dst, src, line, col, minIndent);
		if (src[0] == '{')
			return parseFlowMappingImpl(dst, src, line, col, minIndent);
		if (src[0] == '\'')
		{
			YamlValue.YamlString s;
			immutable consumed = parseSingleQuotedImpl(s, src, line, col, minIndent);
			dst = s;
			return consumed;
		}
		if (src[0] == '"')
		{
			YamlValue.YamlString s;
			immutable consumed = parseDoubleQuotedImpl(s, src, line, col, minIndent);
			dst = s;
			return consumed;
		}
		if (isPlainScalarTerminator(src, true))
		{
			throw new YamlParseException(
				format("Unexpected character '%s' while expecting a flow node", src[0]),
				0, line, col);
		}
		
		YamlValue.YamlString raw;
		immutable consumed = parsePlainScalarImpl(raw, src, line, col, minIndent, true);
		resolveScalarTypeImpl(dst, raw.value[]);
		return consumed;
	}
	
	/***************************************************************************
	 * flowシーケンス（`[...]`）をパースする
	 * 
	 * 要素はカンマ区切りで読み取り、最後の要素の直後の余分な `,` を1つだけ
	 * 許容する（ケツカンマ）。YAML仕様が認める
	 * シーケンス内マッピング省略記法（`[a: 1]` のような `ns-flow-pair`）には
	 * 対応しない。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`src[0]` が `[` であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 内部のplainスカラーへ引き継ぐ最小インデント
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      閉じ角括弧に到達せずEOFに達した場合、または `,` / `]` 以外の
	 *      予期しないトークンに遭遇した場合 `YamlParseException`
	 */
	size_t parseFlowSequenceImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		assert(src.length > 0 && src[0] == '[', "Expected opening bracket");
		
		immutable startLine = line;
		immutable startCol  = col;
		size_t i = 1;
		col++;
		
		auto ary = allocAry!YamlValue;
		bool trailingComma;
		bool singleLine = true;
		
		while (true)
		{
			immutable lineBeforeGap1 = line;
			i += skipFlowSpacingImpl(src[i .. $], line, col);
			if (line != lineBeforeGap1)
				singleLine = false;
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated flow sequence", i, startLine, startCol);
			}
			if (src[i] == ']')
			{
				i++;
				col++;
				break;
			}
			
			YamlValue elem;
			i += parseFlowNodeImpl(elem, src[i .. $], line, col, minIndent);
			ary ~= elem;
			trailingComma = false;
			
			immutable lineBeforeGap2 = line;
			i += skipFlowSpacingImpl(src[i .. $], line, col);
			if (line != lineBeforeGap2)
				singleLine = false;
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated flow sequence", i, startLine, startCol);
			}
			if (src[i] == ',')
			{
				i++;
				col++;
				trailingComma = true;
				continue;
			}
			if (src[i] == ']')
			{
				i++;
				col++;
				break;
			}
			throw new YamlParseException(
				format("Expected ',' or ']' in flow sequence, found '%s'", src[i]),
				i, line, col);
		}
		
		auto seq = YamlValue.YamlSequence(ary);
		seq.style = CollectionStyle.flow;
		seq.trailingComma = trailingComma;
		seq.singleLine = singleLine;
		attachAllPendingTrailingCommentsImpl(seq.trailingComments);
		dst = seq;
		return i;
	}
	
	/***************************************************************************
	 * flowマッピング（`{...}`）をパースする
	 * 
	 * エントリはカンマ区切りで読み取り、最後のエントリの直後の余分な `,` を
	 * 1つだけ許容する（ケツカンマ）。キーはスカラー
	 * （plain/quoted）のみをサポートし、`[`/`{`/`?` で始まる非スカラー・
	 * 明示キーは非対応としてエラーにする。値を省略したエントリ
	 * （`{a, b: 1}` の `a`）はYAML仕様の `e-node` に対応する暗黙のnullとして
	 * 解決し、キー自体を省略した `{: 1}` のような記法（同じく仕様上の
	 * `e-node ":" ...`）も空文字列キーとして受理する。マッピングキーの重複は
	 * パースエラーとする。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`src[0]` が `{` であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 内部のplainスカラーへ引き継ぐ最小インデント
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      閉じ波括弧に到達せずEOFに達した場合、非対応キー・重複キー・
	 *      予期しないトークンに遭遇した場合 `YamlParseException`
	 */
	size_t parseFlowMappingImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		assert(src.length > 0 && src[0] == '{', "Expected opening brace");
		
		immutable startLine = line;
		immutable startCol  = col;
		size_t i = 1;
		col++;
		
		auto dic = allocDic!(YamlKey, YamlValue);
		bool trailingComma;
		bool singleLine = true;
		
		while (true)
		{
			immutable lineBeforeGap1 = line;
			i += skipFlowSpacingImpl(src[i .. $], line, col);
			if (line != lineBeforeGap1)
				singleLine = false;
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated flow mapping", i, startLine, startCol);
			}
			if (src[i] == '}')
			{
				i++;
				col++;
				break;
			}
			
			if (src[i] == '[' || src[i] == '{' || src[i] == '?')
			{
				throw new YamlParseException(
					"Non-scalar or explicit keys are not supported", i, line, col);
			}
			
			YamlValue.YamlString keyContent;
			ScalarStyle keyStyle = ScalarStyle.plain;
			if (src[i] == '\'')
			{
				keyStyle = ScalarStyle.singleQuoted;
				i += parseSingleQuotedImpl(keyContent, src[i .. $], line, col, minIndent);
			}
			else if (src[i] == '"')
			{
				keyStyle = ScalarStyle.doubleQuoted;
				i += parseDoubleQuotedImpl(keyContent, src[i .. $], line, col, minIndent);
			}
			else if (src[i] == ':')
			{
				// 空キー（YAML仕様の `e-node ":" ...`）。コロン自体はまだ消費せず、
				// 後続の共通処理（キー/値セパレータ判定）に合流させる。
				keyContent = YamlValue.YamlString(allocStr());
			}
			else if (isPlainScalarTerminator(src[i .. $], true))
			{
				throw new YamlParseException(
					format("Unexpected character '%s' while expecting a mapping key", src[i]),
					i, line, col);
			}
			else
			{
				i += parsePlainScalarImpl(keyContent, src[i .. $], line, col, minIndent, true);
			}
			auto key = YamlKey(keyContent.value, keyStyle);
			
			if (dic.opIn(key) !is null)
			{
				throw new YamlParseException(
					format("Duplicate key '%s' in mapping", cast(string)key.value), i, line, col);
			}
			
			immutable lineBeforeGap2 = line;
			i += skipFlowSpacingImpl(src[i .. $], line, col);
			if (line != lineBeforeGap2)
				singleLine = false;
			
			YamlValue val;
			if (i < src.length && src[i] == ':')
			{
				i++;
				col++;
				immutable lineBeforeGap3 = line;
				i += skipFlowSpacingImpl(src[i .. $], line, col);
				if (line != lineBeforeGap3)
					singleLine = false;
				if (i >= src.length)
				{
					throw new YamlParseException(
						"Unterminated flow mapping", i, startLine, startCol);
				}
				i += parseFlowNodeImpl(val, src[i .. $], line, col, minIndent);
			}
			else
			{
				auto n = YamlValue.YamlNull();
				n.raw = allocStr();
				val = n;
			}
			
			dic.append(key, val);
			trailingComma = false;
			
			immutable lineBeforeGap4 = line;
			i += skipFlowSpacingImpl(src[i .. $], line, col);
			if (line != lineBeforeGap4)
				singleLine = false;
			if (i >= src.length)
			{
				throw new YamlParseException(
					"Unterminated flow mapping", i, startLine, startCol);
			}
			if (src[i] == ',')
			{
				i++;
				col++;
				trailingComma = true;
				continue;
			}
			if (src[i] == '}')
			{
				i++;
				col++;
				break;
			}
			throw new YamlParseException(
				format("Expected ',' or '}' in flow mapping, found '%s'", src[i]),
				i, line, col);
		}
		
		auto mapping = YamlValue.YamlMapping(dic);
		mapping.style = CollectionStyle.flow;
		mapping.trailingComma = trailingComma;
		mapping.singleLine = singleLine;
		attachAllPendingTrailingCommentsImpl(mapping.trailingComments);
		dst = mapping;
		return i;
	}
	
	// blockコレクションパーサ（シーケンス `- `、マッピング `key:`、ネスト処理、キー重複検出）
	
	/***************************************************************************
	 * 現在位置がblockシーケンスの項目インジケータ（`-` + 空白/改行/EOF）かどうかを判定する
	 * 
	 * `-5`や`-foo`のような負数・plainスカラーの先頭の`-`、および`---`
	 * （ドキュメント開始マーカー、非対応）とは`src[1]`の後続文字で区別する。
	 */
	bool isBlockSequenceIndicatorImpl(in char[] src) const pure nothrow @nogc @safe
	{
		if (src.length == 0 || src[0] != '-')
			return false;
		if (src.length == 1)
			return true;
		return src[1] == ' ' || src[1] == '\t' || src[1] == '\n' || src[1] == '\r';
	}
	
	/***************************************************************************
	 * 現在位置が明示キーインジケータ（`?` + 空白/改行/EOF）かどうかを判定する
	 * 
	 * 明示キー（`? key` / `: value`記法）はY9方針（非スカラーキー非対応）と
	 * スコープを共有する高度な機能のため本実装では非対応とし、検出した場合は
	 * `parseBlockNodeImpl`で明示的にエラーにする（設計スコープ外の簡略化）。
	 */
	bool isExplicitKeyIndicatorImpl(in char[] src) const pure nothrow @nogc @safe
	{
		if (src.length == 0 || src[0] != '?')
			return false;
		if (src.length == 1)
			return true;
		return src[1] == ' ' || src[1] == '\t' || src[1] == '\n' || src[1] == '\r';
	}
	
	/***************************************************************************
	 * 現在行（改行まで）にblockマッピングのキー/値セパレータとなる`:`が
	 * 存在するかどうかを判定する（コロン先読み）
	 * 
	 * シングル/ダブルクォートの範囲は内容として読み飛ばし、その中の`:`は
	 * セパレータ候補としてカウントしない。空白直前の`#`はコメント開始とみなし、
	 * それ以降は走査しない（コメント内の`:`を誤検出しないため）。
	 * 本実装ではキーは単一行のみを対象とする簡略化を採用しているため、
	 * 改行に到達した時点で「この行にはコロンなし」として`false`を返す。
	 * Params:
	 *      src = 現在位置からの文字列
	 * Returns:
	 *      この行にマッピングキーのセパレータとなる`:`があれば`true`
	 */
	bool lineHasMappingColonImpl(in char[] src) const pure nothrow @nogc @safe
	{
		size_t i;
		while (i < src.length)
		{
			immutable c = src[i];
			if (c == '\n' || c == '\r')
				return false;
			if (c == '\'')
			{
				i++;
				while (i < src.length && src[i] != '\n' && src[i] != '\r' && src[i] != '\'')
					i++;
				if (i < src.length && src[i] == '\'')
					i++;
				continue;
			}
			if (c == '"')
			{
				i++;
				while (i < src.length && src[i] != '\n' && src[i] != '\r' && src[i] != '"')
				{
					if (src[i] == '\\' && i + 1 < src.length
						&& src[i + 1] != '\n' && src[i + 1] != '\r')
					{
						i++;
					}
					i++;
				}
				if (i < src.length && src[i] == '"')
					i++;
				continue;
			}
			if (c == ':' && (i + 1 >= src.length || src[i + 1] == ' ' || src[i + 1] == '\t'
				|| src[i + 1] == '\n' || src[i + 1] == '\r'))
			{
				return true;
			}
			if (c == '#' && (i == 0 || src[i - 1] == ' ' || src[i - 1] == '\t'))
				return false;
			i++;
		}
		return false;
	}
	
	/***************************************************************************
	 * 空行およびコメントのみの行を読み飛ばす
	 * 
	 * 呼び出し時点で行頭（直前に改行を消費済み、またはドキュメント先頭）に
	 * 位置していることを前提とする。実コンテンツを持つ行、またはEOFに到達した
	 * 時点でそれ以上読み進めず終了する（その行自体のインデントは消費しない。
	 * 呼び出し元が改めて`measureIndentImpl`でインデント量を測る）。
	 * コメントのみの行は、その本文とインデント量を`_pendingComments`に蓄積する。
	 * 実際にどのノードへ付与するかは
	 * `attachPendingLeadingCommentsImpl`/`attachPendingTrailingCommentsAtOrDeeperImpl`
	 * が後で決定する。
	 * Params:
	 *      src  = 現在位置（行頭）からの文字列
	 *      line = 行番号（改行のたびに更新される）
	 *      col  = 列番号（消費した文字数だけ更新される）
	 * Returns:
	 *      消費した文字数
	 */
	size_t skipBlankAndCommentLinesImpl(in char[] src, ref size_t line, ref size_t col) @safe
	{
		size_t i;
		while (true)
		{
			size_t peekCol = col;
			immutable indentLen = measureIndentImpl(src[i .. $], line, peekCol);
			auto afterIndent = src[i + indentLen .. $];
			immutable isBlank = afterIndent.length == 0
				|| afterIndent[0] == '\n' || afterIndent[0] == '\r';
			immutable isCommentOnly = !isBlank && afterIndent[0] == '#';
			if (!isBlank && !isCommentOnly)
				break;
			i += indentLen;
			col = peekCol;
			if (isCommentOnly)
			{
				String text;
				immutable commentLen = parseCommentTextImpl(text, src[i .. $], col);
				_pendingComments ~= PendingComment(text, indentLen);
				i += commentLen;
			}
			if (i < src.length && (src[i] == '\n' || src[i] == '\r'))
			{
				immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
				i += nlLen;
				continue;
			}
			break;
		}
		return i;
	}
	
	/***************************************************************************
	 * blockシーケンス項目・blockマッピングエントリに共通する「値」の決定・パースを行う
	 * 
	 * 以下の優先順位で値を決定する:
	 * 1. 同一行に内容がある場合 → その位置から`parseBlockNodeImpl`で値としてパース
	 *    （`- key: value`のようなシーケンス項目としてのインラインマッピングや、
	 *    `- - 1`のようなコンパクトなネストシーケンスも含め、フルディスパッチャに
	 *    委ねることで自然に対応できる。`key: sub: value`のような同一行ネストは
	 *    通常のYAMLでは想定されない書き方だが、実装を単純化するため本実装では
	 *    区別せず同じ経路で扱う簡略化を採用した）
	 * 2. 改行後、より深いインデントの行がある場合 → その行から`parseBlockNodeImpl`
	 *    でネストした値としてパース
	 * 3. （`allowSameIndentSequence`が`true`の場合のみ）改行後、エントリ自身と
	 *    同じインデントでblockシーケンス項目（`- `）が続く場合 → YAML仕様が
	 *    認める「マッピング値としてのシーケンスはキーと同じインデントでもよい」
	 *    規則に対応し、`parseBlockSequenceImpl`でパースする
	 *    （blockマッピングの値としてのみ許可。シーケンス項目自身の値には適用しない）
	 * 4. いずれにも該当しない場合 → 暗黙のnull。この場合、後続行の
	 *    インデントは消費せず呼び出し元（マッピング/シーケンスのループ）に委ねる
	 * 
	 * 空行・コメントのみの行は`skipBlankAndCommentLinesImpl`により読み飛ばされる。
	 * Params:
	 *      dst                     = パース結果の格納先
	 *      src                     = `-`または`:`の直後の位置からの文字列
	 *      line                    = 行番号（改行のたびに更新される）
	 *      col                     = 列番号（消費した文字数だけ更新される）
	 *      ownIndent               = このエントリ自身（`-`またはキー）のインデント量
	 *      allowSameIndentSequence = 上記3.の同一インデントシーケンス規則を
	 *                                適用するかどうか（blockマッピングの値のみ`true`）
	 * Returns:
	 *      消費した文字数
	 */
	size_t parseBlockEntryValueImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t ownIndent, bool allowSameIndentSequence) @safe
	{
		size_t i;
		while (i < src.length && (src[i] == ' ' || src[i] == '\t'))
		{
			i++;
			col++;
		}
		
		bool restOfLineEmpty;
		if (i >= src.length || src[i] == '\n' || src[i] == '\r')
		{
			restOfLineEmpty = true;
		}
		else if (src[i] == '#')
		{
			while (i < src.length && src[i] != '\n' && src[i] != '\r')
			{
				i++;
				col++;
			}
			restOfLineEmpty = true;
		}
		
		if (!restOfLineEmpty)
		{
			immutable valConsumed = parseBlockNodeImpl(dst, src[i .. $], line, col, ownIndent);
			i += valConsumed;
			return i;
		}
		
		if (i < src.length && (src[i] == '\n' || src[i] == '\r'))
		{
			immutable nlLen = skipNewlineImpl(src[i .. $], line, col);
			i += nlLen;
		}
		
		i += skipBlankAndCommentLinesImpl(src[i .. $], line, col);
		
		if (i >= src.length)
		{
			auto n = YamlValue.YamlNull();
			n.raw = allocStr();
			dst = n;
			return i;
		}
		
		size_t peekCol = col;
		immutable indentLen = measureIndentImpl(src[i .. $], line, peekCol);
		auto afterIndent = src[i + indentLen .. $];
		
		if (indentLen > ownIndent)
		{
			i += indentLen;
			col = peekCol;
			immutable valConsumed = parseBlockNodeImpl(dst, src[i .. $], line, col, ownIndent);
			i += valConsumed;
			return i;
		}
		
		if (allowSameIndentSequence && indentLen == ownIndent
			&& isBlockSequenceIndicatorImpl(afterIndent))
		{
			i += indentLen;
			col = peekCol;
			immutable valConsumed = parseBlockNodeImpl(dst, src[i .. $], line, col, ownIndent);
			i += valConsumed;
			return i;
		}
		
		auto n = YamlValue.YamlNull();
		n.raw = allocStr();
		dst = n;
		return i;
	}
	
	/***************************************************************************
	 * blockシーケンス（`- item`）をパースする
	 * 
	 * 最初の項目インジケータ`-`の列位置がこのシーケンスの確立インデント
	 * （`ownIndent`）となり、以後の項目は同じ列でなければならない。
	 * `minIndent`引数はシグネチャ統一契約により受け取るが、確立インデントは
	 * 呼び出し時点の`col`から自己導出するため本体では使用しない
	 * （`parseSingleQuotedImpl`等と同様の理由）。
	 * 
	 * ループ継続判定:
	 * - 次行のインデントが`ownIndent`未満 → シーケンス終了（正常、呼び出し元へ戻す）
	 * - 次行のインデントが`ownIndent`と同じで`-`項目が続く → 継続
	 * - 次行のインデントが`ownIndent`と同じだが`-`項目でない → シーケンス終了
	 *   （正常。例えばマッピングキーの値として同一インデントで書かれたシーケンスが
	 *   終わり、後続のマッピングキーに制御を戻すケースに対応）
	 * - 次行のインデントが`ownIndent`を超える → 不正なインデントとしてエラー
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（`isBlockSequenceIndicatorImpl(src)`が
	 *                  `true`であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = シグネチャ統一のために受け取るが使用しない（上記参照）
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      インデントに矛盾がある場合 `YamlParseException`
	 */
	/***************************************************************************
	 * エントリの値をパースした直後、その行に想定外の残存内容がないことを検証する
	 * 
	 * plainスカラーの複数行折り畳みは、折り畳んだ継続行の途中で埋め込みの
	 * セパレータ（コロン+空白等）に遭遇すると、その位置で（行の途中であっても）
	 * 終了する。そのため値パース直後の位置が必ずしも「行末」になるとは限らない。
	 * このような残存内容を検知せずに次のエントリ探索へ進んでしまうと、その位置を
	 * 誤って次の行の先頭であるかのようにインデント量を測ってしまい、
	 * `parsePlainScalarImpl`側のアサーション違反など不可解な失敗につながる。
	 * 本関数で行末（空白・コメント・改行・EOF）以外の内容を明示的に検出し、
	 * 分かりやすい構文エラーとして報告する（本体の定義は後述の通り拡張され
	 * 末尾コメントの捕捉も行うようになったため、Parserセクション末尾を参照）。
	 */
	
	size_t parseBlockSequenceImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		immutable ownIndent = col - 1;
		auto ary = allocAry!YamlValue;
		size_t i;
		
		while (true)
		{
			assert(i < src.length && isBlockSequenceIndicatorImpl(src[i .. $]),
				"parseBlockSequenceImpl loop invariant violated");
			i++;
			col++;
			
			YamlValue elem;
			immutable valConsumed = parseBlockEntryValueImpl(elem, src[i .. $], line, col, ownIndent, false);
			i += valConsumed;
			ary ~= elem;
			
			i += skipBlankAndCommentLinesImpl(src[i .. $], line, col);
			if (i >= src.length)
				break;
			
			size_t peekCol = col;
			immutable indentLen = measureIndentImpl(src[i .. $], line, peekCol);
			if (indentLen < ownIndent)
				break;
			if (indentLen > ownIndent)
			{
				throw new YamlParseException(
					"Inconsistent indentation in block sequence", i + indentLen, line, peekCol);
			}
			if (!isBlockSequenceIndicatorImpl(src[i + indentLen .. $]))
				break;
			
			i += indentLen;
			col = peekCol;
		}
		
		auto seq = YamlValue.YamlSequence(ary);
		seq.style = CollectionStyle.block;
		attachPendingTrailingCommentsAtOrDeeperImpl(seq.trailingComments, ownIndent);
		dst = seq;
		return i;
	}
	
	/***************************************************************************
	 * blockマッピング（`key: value`）をパースする
	 * 
	 * 最初のキーの列位置がこのマッピングの確立インデント（`ownIndent`）となり、
	 * 以後のキーは同じ列でなければならない。キーはplain/quotedスカラーのみを
	 * サポートし、`[`/`{`で始まる非スカラーキー・`?`で始まる明示キーは
	 * 非対応としてエラーにする。マッピングキーの重複はパースエラーとする。
	 * `minIndent`引数は`parseBlockSequenceImpl`と同様の
	 * 理由でシグネチャ統一のために受け取るが本体では使用しない。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（キー候補の開始位置）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = シグネチャ統一のために受け取るが使用しない
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      非対応キー・重複キー・コロン欠落・インデント矛盾の場合
	 *      `YamlParseException`
	 */
	size_t parseBlockMappingImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		immutable ownIndent = col - 1;
		auto dic = allocDic!(YamlKey, YamlValue);
		size_t i;
		
		while (true)
		{
			if (src[i] == '[' || src[i] == '{')
			{
				throw new YamlParseException(
					"Non-scalar keys are not supported", i, line, col);
			}
			if (isExplicitKeyIndicatorImpl(src[i .. $]))
			{
				throw new YamlParseException(
					"Explicit ('?') keys are not supported", i, line, col);
			}
			
			YamlValue.YamlString keyContent;
			ScalarStyle keyStyle = ScalarStyle.plain;
			if (src[i] == '\'')
			{
				keyStyle = ScalarStyle.singleQuoted;
				i += parseSingleQuotedImpl(keyContent, src[i .. $], line, col, ownIndent);
			}
			else if (src[i] == '"')
			{
				keyStyle = ScalarStyle.doubleQuoted;
				i += parseDoubleQuotedImpl(keyContent, src[i .. $], line, col, ownIndent);
			}
			else
			{
				i += parsePlainScalarImpl(keyContent, src[i .. $], line, col, ownIndent, false);
			}
			auto key = YamlKey(keyContent.value, keyStyle);
			
			while (i < src.length && (src[i] == ' ' || src[i] == '\t'))
			{
				i++;
				col++;
			}
			if (i >= src.length || src[i] != ':')
			{
				throw new YamlParseException(
					"Expected ':' after mapping key", i, line, col);
			}
			i++;
			col++;
			
			if (dic.opIn(key) !is null)
			{
				throw new YamlParseException(
					format("Duplicate key '%s' in mapping", cast(string)key.value), i, line, col);
			}
			
			YamlValue val;
			immutable valConsumed = parseBlockEntryValueImpl(val, src[i .. $], line, col, ownIndent, true);
			i += valConsumed;
			dic.append(key, val);
			
			i += skipBlankAndCommentLinesImpl(src[i .. $], line, col);
			if (i >= src.length)
				break;
			
			size_t peekCol = col;
			immutable indentLen = measureIndentImpl(src[i .. $], line, peekCol);
			if (indentLen < ownIndent)
				break;
			if (indentLen > ownIndent)
			{
				throw new YamlParseException(
					"Inconsistent indentation in block mapping", i + indentLen, line, peekCol);
			}
			checkNoDocumentMarkerImpl(src[i + indentLen .. $], i + indentLen, line, peekCol);
			
			i += indentLen;
			col = peekCol;
		}
		
		auto mapping = YamlValue.YamlMapping(dic);
		mapping.style = CollectionStyle.block;
		attachPendingTrailingCommentsAtOrDeeperImpl(mapping.trailingComments, ownIndent);
		dst = mapping;
		return i;
	}
	
	/***************************************************************************
	 * blockノード（スカラー・blockコレクション・flowコレクション）を1つパースする
	 * 
	 * 現在位置の内容から種類を判定し、対応するパーサへディスパッチする
	 * （文書区切り記号の判定は`parse()`側で対応するためここでは扱わない）:
	 * 1. blockスカラー（`|`/`>`）
	 * 2. flowコレクション（`[`/`{`）
	 * 3. blockシーケンス項目（`-` + 空白/改行/EOF）
	 * 4. 明示キー（`?`） → 非対応としてエラー
	 * 5. マッピングキー候補（コロン先読み、`lineHasMappingColonImpl`）
	 * 6. quoted文字列（単独の値として。マッピングキーでないことは5.で除外済み）
	 * 7. plainスカラー（既定）
	 * 
	 * 「葉」となる値のうちflowコレクション（2.）・quoted文字列（6.）・
	 * plainスカラー（7.）をパースした直後は`expectEndOfLineImpl`で行末までの
	 * 残存内容を検証する。plainスカラーの複数行折り畳みが埋め込みの
	 * セパレータ（コロン+空白等）で行の途中に停止するケースや、flow
	 * コレクションの閉じ括弧の直後に余分な文字が続くケースがある
	 * ためである。一方、blockスカラー（1.）とblockコレクション（3./5.）は
	 * インデントに基づいて行境界で必ず終了する（行の途中で止まることがない）ため
	 * ここでは検証しない（検証してしまうと、ネストした値の直後に続く
	 * 「呼び出し元の次のエントリ」を誤って「同一行の残存ゴミ」と誤検知してしまう）。
	 * 
	 * 冒頭で`skipBlankAndCommentLinesImpl`を呼び、先頭の空行・コメント行を
	 * 自ら読み飛ばしてから内容を判定する。通常は呼び出し元
	 * （`parseBlockEntryValueImpl`）が既に読み飛ばし済みのため冪等な無駄呼び出しに
	 * なるだけだが、これにより「ドキュメント先頭のコメント」のように、
	 * 事前の読み飛ばしを経由せず直接本関数が呼ばれるケース（`parse()`でのルート
	 * ノード呼び出しを想定）でも一貫してleading commentを捕捉できる。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（内容開始位置である必要はなく、
	 *                  先頭に空行・コメント行が残っていてもよい）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 親（呼び出し元のエントリ）自身のインデント量。
	 *                  blockスカラーへはそのまま、plainスカラーへは
	 *                  `minIndent + 1`として引き継ぐ
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      明示キー（`?`）に遭遇した場合、または葉の値の直後に同一行の
	 *      予期しない内容が残っている場合 `YamlParseException`
	 */
	size_t parseBlockNodeImpl(ref YamlValue dst, in char[] src,
		ref size_t line, ref size_t col, size_t minIndent) @safe
	{
		immutable skipped = skipBlankAndCommentLinesImpl(src, line, col);
		auto rest = src[skipped .. $];
		
		attachPendingLeadingCommentsImpl(dst);
		
		if (rest.length == 0)
		{
			auto n = YamlValue.YamlNull();
			n.raw = allocStr();
			dst = n;
			return skipped;
		}
		
		if (rest[0] == '&')
		{
			col++;
			String anchorName;
			immutable nameLen = parseAnchorNameImpl(anchorName, rest[1 .. $], col);
			if (nameLen == 0)
			{
				throw new YamlParseException(
					"Anchor name must not be empty", skipped + 1, line, col);
			}
			immutable valConsumed = parseBlockEntryValueImpl(
				dst, rest[1 + nameLen .. $], line, col, minIndent, false);
			dst._anchor = nullable(anchorName);
			registerAnchorImpl(anchorName, dst);
			return skipped + 1 + nameLen + valConsumed;
		}
		if (rest[0] == '*')
		{
			col++;
			String aliasName;
			immutable nameLen = parseAnchorNameImpl(aliasName, rest[1 .. $], col);
			if (nameLen == 0)
			{
				throw new YamlParseException(
					"Alias name must not be empty", skipped + 1, line, col);
			}
			dst = resolveAliasImpl(aliasName, skipped + 1, line, col);
			return skipped + 1 + nameLen;
		}
		if (rest[0] == '!')
		{
			String tagName;
			immutable tagLen = parseTagImpl(tagName, rest, line, col);
			immutable valConsumed = parseBlockEntryValueImpl(
				dst, rest[tagLen .. $], line, col, minIndent, false);
			dst._tag = nullable(tagName);
			return skipped + tagLen + valConsumed;
		}
		
		if (rest[0] == '|' || rest[0] == '>')
		{
			YamlValue.YamlString s;
			immutable consumed = parseBlockScalarImpl(s, rest, line, col, minIndent);
			dst = s;
			return skipped + consumed;
		}
		if (rest[0] == '[')
		{
			immutable consumed = parseFlowSequenceImpl(dst, rest, line, col, minIndent);
			return skipped + consumed + expectEndOfLineImpl(dst, rest[consumed .. $], line, col);
		}
		if (rest[0] == '{')
		{
			immutable consumed = parseFlowMappingImpl(dst, rest, line, col, minIndent);
			return skipped + consumed + expectEndOfLineImpl(dst, rest[consumed .. $], line, col);
		}
		if (isBlockSequenceIndicatorImpl(rest))
			return skipped + parseBlockSequenceImpl(dst, rest, line, col, minIndent);
		if (isExplicitKeyIndicatorImpl(rest))
		{
			throw new YamlParseException(
				"Explicit ('?') keys are not supported", skipped, line, col);
		}
		if (lineHasMappingColonImpl(rest))
			return skipped + parseBlockMappingImpl(dst, rest, line, col, minIndent);
		if (rest[0] == '\'')
		{
			YamlValue.YamlString s;
			immutable consumed = parseSingleQuotedImpl(s, rest, line, col, minIndent);
			dst = s;
			return skipped + consumed + expectEndOfLineImpl(dst, rest[consumed .. $], line, col);
		}
		if (rest[0] == '"')
		{
			YamlValue.YamlString s;
			immutable consumed = parseDoubleQuotedImpl(s, rest, line, col, minIndent);
			dst = s;
			return skipped + consumed + expectEndOfLineImpl(dst, rest[consumed .. $], line, col);
		}
		
		YamlValue.YamlString raw;
		immutable consumed = parsePlainScalarImpl(raw, rest, line, col, minIndent + 1, false);
		resolveScalarTypeImpl(dst, raw.value[]);
		return skipped + consumed + expectEndOfLineImpl(dst, rest[consumed .. $], line, col);
	}
	
	// コメント位置復元ロジック
	
	/***************************************************************************
	 * 保留中のコメント1件を表す内部構造体
	 * 
	 * `indentLen`はそのコメント自身の行頭からの空白文字数（`measureIndentImpl`と
	 * 同じ単位）。flow文脈で捕捉されたコメントについては、flowコレクションの
	 * 境界は角括弧の対応により曖昧さなく決まるため、この値は意味を持たない
	 * （インデント比較はblock文脈のdanglingコメント判定にのみ使う）。
	 */
	static struct PendingComment
	{
		///
		String text;
		///
		size_t indentLen;
	}
	
	/// 保留中コメントのキュー（`skipBlankAndCommentLinesImpl`/`skipFlowSpacingImpl`で
	/// 蓄積され、`attachPendingLeadingCommentsImpl`等で取り出される）
	Array!PendingComment _pendingComments;
	
	/***************************************************************************
	 * `#`から行末までのコメント本文を読み取る
	 * 
	 * `#`自体は結果の`dst`には含めない（stringify時に`"#" ~ dst`で正確に
	 * 再現できるよう、`#`直後の空白の有無・個数をそのまま保持する）。
	 * YAMLのコメントは単一行に限られるため改行はまたがない。
	 * Params:
	 *      dst = 読み取ったコメント本文（`#`を除く）の格納先
	 *      src = 現在位置からの文字列（`src[0]`が`#`であること）
	 *      col = 列番号（消費した文字数だけ更新される）
	 * Returns:
	 *      消費した文字数（`#`を含む）
	 */
	size_t parseCommentTextImpl(ref String dst, in char[] src, ref size_t col) @safe
	{
		assert(src.length > 0 && src[0] == '#', "Expected '#' comment indicator");
		size_t i = 1;
		while (i < src.length && src[i] != '\n' && src[i] != '\r')
			i++;
		dst = allocStr();
		dst ~= src[1 .. i];
		col += i;
		return i;
	}
	
	/***************************************************************************
	 * 保留中のリーディングコメントをすべて`dst`に付与し、
	 * キューを空にする
	 * 
	 * `parseBlockNodeImpl`/`parseFlowNodeImpl`の冒頭で無条件に呼び出す。
	 * `dst`はこの時点でまだ実際の値を代入されていない状態でもよい
	 * （`opAssign`は`_comments`を保持したまま`_instance`のみ差し替えるため、
	 * 後から`dst = 実際の値;`としても本メソッドで付与したコメントは残る）。
	 * Params:
	 *      dst = コメントの付与先
	 */
	void attachPendingLeadingCommentsImpl(ref YamlValue dst) @safe
	{
		foreach (ref pc; _pendingComments[])
			dst.addLineComment(pc.text[]);
		_pendingComments = allocAry!PendingComment;
	}
	
	/***************************************************************************
	 * 保留中のコメントのうち、指定インデント以上のものだけを取り出し`dst`に付与する
	 * （blockコレクションのdangling comment）
	 * 
	 * インデントが`ownIndent`未満のコメントはこのコレクションには属さず、
	 * より外側の呼び出し元が後で解決すべきものとしてキューに残す
	 * （gopkg.in/yaml.v3の実バグ事例を踏まえ、単純にキュー全体を
	 * 消費してしまわないよう設計）。
	 * `parseBlockSequenceImpl`/`parseBlockMappingImpl`のループ終了直後
	 * （どの`break`経路であっても合流する箇所）で呼び出す。
	 * Params:
	 *      dst       = コメントの付与先（`YamlSequence.trailingComments`等）
	 *      ownIndent = このコレクション自身の確立インデント
	 */
	void attachPendingTrailingCommentsAtOrDeeperImpl(
		ref Array!(YamlValue.Comment) dst, size_t ownIndent) @safe
	{
		auto remaining = allocAry!PendingComment;
		foreach (ref pc; _pendingComments[])
		{
			if (pc.indentLen >= ownIndent)
			{
				auto c = allocStr();
				c ~= pc.text[];
				dst ~= YamlValue.Comment(YamlValue.LineComment(c));
			}
			else
			{
				remaining ~= pc;
			}
		}
		_pendingComments = remaining;
	}
	
	/***************************************************************************
	 * 保留中のコメントを無条件にすべて取り出し`dst`に付与する
	 * （flowコレクションのdangling comment）
	 * 
	 * flowコレクションの範囲は角括弧/波括弧の対応により曖昧さなく決まるため、
	 * blockコレクションのようなインデント比較（`attachPendingTrailingCommentsAtOrDeeperImpl`）
	 * は不要。`parseFlowSequenceImpl`/`parseFlowMappingImpl`が閉じ括弧に
	 * 到達した直後に呼び出す。
	 * Params:
	 *      dst = コメントの付与先
	 */
	void attachAllPendingTrailingCommentsImpl(ref Array!(YamlValue.Comment) dst) @safe
	{
		foreach (ref pc; _pendingComments[])
		{
			auto c = allocStr();
			c ~= pc.text[];
			dst ~= YamlValue.Comment(YamlValue.LineComment(c));
		}
		_pendingComments = allocAry!PendingComment;
	}
	
	/***************************************************************************
	 * 値をパースした直後、その行に想定外の残存内容がないことを検証し、
	 * 同一行の末尾コメントがあれば`dst`のtrailing commentとして
	 * 付与する
	 * Params:
	 *      dst  = パース済みの値。末尾コメントがあればここに付与する
	 *      src  = 値の直後の位置からの文字列
	 *      line = 行番号
	 *      col  = 列番号（読み飛ばした行末空白・コメントの分だけ更新される）
	 * Returns:
	 *      読み飛ばした文字数（行末空白＋コメントがあればその分も含む）
	 * Throws:
	 *      行末（空白・コメント・改行・EOF）以外の内容が残っている場合
	 *      `YamlParseException`
	 */
	size_t expectEndOfLineImpl(ref YamlValue dst, in char[] src, ref size_t line, ref size_t col) @safe
	{
		size_t j;
		while (j < src.length && (src[j] == ' ' || src[j] == '\t'))
		{
			j++;
			col++;
		}
		if (j < src.length && src[j] == '#')
		{
			String text;
			immutable commentLen = parseCommentTextImpl(text, src[j .. $], col);
			dst.addTrailingComment(text[]);
			j += commentLen;
			return j;
		}
		if (j < src.length && src[j] != '\n' && src[j] != '\r')
		{
			throw new YamlParseException(
				format("Unexpected content '%s' after value, expected end of line", src[j]),
				j, line, col);
		}
		return j;
	}
	
	// アンカー・エイリアスパーサ + anchorTable管理
	
	/// アンカー・エイリアス名の終端文字かどうかを判定する
	/// （空白・改行・flowインジケータ。文脈（block/flow）によらず常に同じ集合とする）
	bool isAnchorNameTerminatorImpl(char c) const pure nothrow @nogc @safe
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r'
			|| c == ',' || c == '[' || c == ']' || c == '{' || c == '}';
	}
	
	/***************************************************************************
	 * `&`または`*`の直後からアンカー・エイリアス名を読み取る
	 * Params:
	 *      dst = 読み取った名前の格納先
	 *      src = `&`/`*`indicatorの直後の位置からの文字列
	 *      col = 列番号（消費した文字数だけ更新される）
	 * Returns:
	 *      消費した文字数（名前が空の場合は0）
	 */
	size_t parseAnchorNameImpl(ref String dst, in char[] src, ref size_t col) @safe
	{
		size_t i;
		while (i < src.length && !isAnchorNameTerminatorImpl(src[i]))
			i++;
		dst = allocStr();
		dst ~= src[0 .. i];
		col += i;
		return i;
	}
	
	// 明示タグパーサ（保持のみ、型解決には未使用）
	
	/***************************************************************************
	 * 明示タグ（`!`で始まるトークン）を読み取る
	 * 
	 * 型解決には使わず、raw文字列として保持するのみ。以下の形式を
	 * 区別せず、いずれも`!`から終端までをそのまま1つの文字列として捕捉する:
	 * `!!str`（セカンダリタグハンドル）・`!mytag`（プライマリタグハンドル）・
	 * `!handle!suffix`（名前付きハンドル。`%TAG`ディレクティブ非対応のため
	 * ハンドルを解決することはないが、構文としては受理し保持する）・
	 * 裸の`!`（非specificタグ、空のサフィックスとして許容する）。
	 * 唯一`!<...>`（verbatim形式）だけは終端規則が異なり、閉じの`>`まで
	 * （角括弧・空白を含めて）読み取る。
	 * Params:
	 *      dst  = 読み取ったタグ文字列（`!`自体を含む）の格納先
	 *      src  = 現在位置からの文字列（`src[0]`が`!`であること）
	 *      line = 行番号（エラー報告にのみ使用）
	 *      col  = 列番号（消費した文字数だけ更新される）
	 * Returns:
	 *      消費した文字数
	 * Throws:
	 *      verbatim形式（`!<...>`）で閉じの`>`が同一行に見つからない場合
	 *      `YamlParseException`
	 */
	size_t parseTagImpl(ref String dst, in char[] src, ref size_t line, ref size_t col) @safe
	{
		assert(src.length > 0 && src[0] == '!', "Expected '!' tag indicator");
		
		if (src.length >= 2 && src[1] == '<')
		{
			size_t i = 2;
			while (i < src.length && src[i] != '>' && src[i] != '\n' && src[i] != '\r')
				i++;
			if (i >= src.length || src[i] != '>')
			{
				throw new YamlParseException(
					"Unterminated verbatim tag (missing '>')", i, line, col);
			}
			i++;
			dst = allocStr();
			dst ~= src[0 .. i];
			col += i;
			return i;
		}
		
		size_t i = 1;
		while (i < src.length && !isAnchorNameTerminatorImpl(src[i]))
			i++;
		dst = allocStr();
		dst ~= src[0 .. i];
		col += i;
		return i;
	}
	
	/// アンカーテーブル。`parse()`の呼び出しごとに新規にクリアされる
	Dictionary!(string, YamlValue) _anchorTable;
	
	/***************************************************************************
	 * アンカーを登録する（同名アンカーが既にあれば上書きする。再アンカーは
	 * YAML仕様上正当であり、以後の`*name`は最新の定義を参照する）
	 * 
	 * ここではdeepCopyせず値をそのまま登録する（複製は`*name`
	 * 出現時に行う契約のため。パースは常に単一パスであり、登録から参照までの
	 * 間に既存ノードが変更されることはないため、登録時点でのdeepCopyは不要）。
	 */
	void registerAnchorImpl(in String name, YamlValue value) @safe
	{
		immutable key = cast(string)name[];
		auto existing = _anchorTable.opIn(key);
		if (existing !is null)
			*existing = value;
		else
			_anchorTable.append(key, value);
	}
	
	/***************************************************************************
	 * `*name`の参照を解決し、`YamlAlias(name, 該当ノードのdeepCopy)`を返す
	 * Throws:
	 *      未定義のアンカーを参照した場合 `YamlParseException`
	 */
	YamlValue resolveAliasImpl(in String name, size_t idx, size_t line, size_t col) @safe
	{
		immutable key = cast(string)name[];
		auto found = _anchorTable.opIn(key);
		if (found is null)
		{
			throw new YamlParseException(
				format("Undefined anchor reference '*%s'", key), idx, line, col);
		}
		auto resolvedCopy = new YamlValue;
		*resolvedCopy = deepCopy(*found);
		YamlValue result;
		result = YamlValue.YamlAlias(name, resolvedCopy);
		return result;
	}
	
	// parse() 統合（単一ドキュメント、BOM処理、複数ドキュメント構文の明示エラー化）
	
	/// 空白・タブ・改行・EOFのいずれかを判定する（ドキュメント区切り記号の
	/// 終端判定に使う小さな補助関数）
	bool isSpaceOrEolImpl(char c) const pure nothrow @nogc @safe
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}
	
	/***************************************************************************
	 * 複数ドキュメント関連構文（行頭`---`・行頭`...`・`%`ディレクティブ行）が
	 * 現在位置に出現していないかを検証する
	 * 
	 * これらは恒久的に非対応と決定されているため、検出した場合は
	 * 「単に無視する」のではなく明示的に`YamlParseException`を送出する
	 * （サイレントな誤動作防止）。`---`/`...`は正確に3文字＋
	 * 空白/改行/EOFが続く場合のみ該当と判定する（`----`のような4文字以上の
	 * ダッシュ列はplainスカラーとして正当なため誤検出しない）。
	 * Params:
	 *      src  = 検査対象の文字列（行頭であることを前提とする）
	 *      idx  = エラー報告用の絶対インデックス
	 *      line = エラー報告用の行番号
	 *      col  = エラー報告用の列番号
	 * Throws:
	 *      複数ドキュメント構文・ディレクティブを検出した場合 `YamlParseException`
	 */
	void checkNoDocumentMarkerImpl(in char[] src, size_t idx, size_t line, size_t col) const @safe
	{
		if (src.length == 0)
			return;
		immutable isTripleDash = src.length >= 3 && src[0 .. 3] == "---"
			&& (src.length == 3 || isSpaceOrEolImpl(src[3]));
		immutable isTripleDot = src.length >= 3 && src[0 .. 3] == "..."
			&& (src.length == 3 || isSpaceOrEolImpl(src[3]));
		immutable isDirective = src[0] == '%';
		if (isTripleDash || isTripleDot || isDirective)
		{
			throw new YamlParseException(
				"Multi-document streams and directives are not supported", idx, line, col);
		}
	}
	
	// ==========================================================================
	// MARK: - - Stringify
	// ==========================================================================
	// スカラー出力（rawテキスト優先方式）
	
	/***************************************************************************
	 * `long`の値を符号なし整数の絶対値へ変換する
	 * 
	 * `-long.min`は`long`の範囲では表現できず単純な符号反転がオーバーフローするため、
	 * `long.min`のみ特別扱いする（`resolveIntegerImpl`の`negLimit`と対になる、
	 * 整数出力側でのraw未設定時のフォールバック用ヘルパー）。
	 * Params:
	 *      v = 変換対象の値
	 * Returns:
	 *      `v`の絶対値（符号なし）
	 */
	ulong absULongImpl(long v) const pure nothrow @nogc @safe
	{
		if (v == long.min)
			return cast(ulong)long.max + 1;
		return v < 0 ? cast(ulong)(-v) : cast(ulong)v;
	}
	
	/***************************************************************************
	 * 与えられた文字列が、プレーンスカラーとして安全に出力できるかどうかを判定する
	 * 
	 * `raw`が未設定の場合（`make()`等による新規構築値を想定）の簡易フォールバック用の
	 * 安全確認であり、YAML仕様上の完全なプレーンスカラー安全性判定ではない
	 * （厳密な安全性判定は値構築・シリアライズ側の責務とする）。
	 * 改行を含む・インジケータ文字で始まる・`": "`や行末`" #"`を含む・
	 * 空文字列である、のいずれかに該当する場合は安全でないと判定する。
	 * Params:
	 *      s = 判定対象の文字列
	 * Returns:
	 *      プレーンスカラーとして安全に出力できる場合`true`
	 */
	bool isSafePlainScalarContentImpl(in char[] s) const @safe
	{
		if (s.length == 0)
			return false;
		if (s.canFind('\n'))
			return false;
		if (s[0].among('-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*',
				'!', '|', '>', '\'', '"', '%', '@', '`', ' '))
		{
			return false;
		}
		if (s.canFind(": ") || s.endsWith(":") || s.canFind(" #"))
			return false;
		return true;
	}
	
	/***************************************************************************
	 * ダブルクォート文字列の内容部分をエスケープして出力する
	 * 
	 * 制御文字・`"`・`\`のみをエスケープする最小限の実装。パース側が
	 * 受理する全エスケープ種別（`\N`/`\_`/`\L`/`\P`等）を出力側でも網羅する
	 * 必要はない（raw優先方針により、quoted文字列は本来rawが
	 * 保持されていればそちらが優先される。ただしquoted文字列の
	 * rawは保持していないため、実際には本関数が主経路となる）。
	 * `escapeNonAscii`が`true`の場合、ASCII範囲外（0x7Fを超える）の
	 * コードポイントを`\uXXXX`（BMP範囲）または`\U XXXXXXXX`（それ以外）で
	 * エスケープする（`YamlPrettyPrintOptions.escapeNonAscii`用。
	 * パース側は`\u`/`\U`両方に対応済みのため対称）。UTF-8の
	 * マルチバイト列をバイト単位ではなくコードポイント単位で判定する
	 * 必要があるため、`content`は`dchar`単位でデコードしながら走査する。
	 * Params:
	 *      dst            = 出力先
	 *      content        = エスケープ対象の文字列（クォート文字は含まない）
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlDoubleQuotedContentImpl(OutputRange)(ref OutputRange dst, in char[] content,
		bool escapeNonAscii = false) const @safe
	{
		foreach (dchar c; content)
		{
			switch (c)
			{
			case '"':  put(dst, "\\\""); break;
			case '\\': put(dst, `\\`); break;
			case '\0': put(dst, `\0`); break;
			case '\a': put(dst, `\a`); break;
			case '\b': put(dst, `\b`); break;
			case '\t': put(dst, `\t`); break;
			case '\n': put(dst, `\n`); break;
			case '\v': put(dst, `\v`); break;
			case '\f': put(dst, `\f`); break;
			case '\r': put(dst, `\r`); break;
			default:
				if (escapeNonAscii && c > 0x7F)
				{
					if (c <= 0xFFFF)
						formattedWrite(dst, "\\u%04X", cast(uint)c);
					else
						formattedWrite(dst, "\\U%08X", cast(uint)c);
				}
				else
				{
					put(dst, c);
				}
				break;
			}
		}
	}
	
	/***************************************************************************
	 * ブロックスカラー（literal `|` / folded `>`）を出力する
	 * 
	 * ヘッダ行（スタイル指示子+chomping指定子）の後、内容を`indentLevel + 1`の
	 * インデントで再構成して出力する。明示インデント指定子（`explicitIndent`）は
	 * 意図的に再出力しない。再構成後の内容は常にクリーンな一定インデントに
	 * 揃うため自動検出で正しく再パースできるが、元の数値をそのまま再出力すると
	 * 出力側のインデント幅と無関係な値になり、再パース時に誤ったバイト数を
	 * 読み飛ばして内容を破壊する危険がある。
	 * Params:
	 *      dst         = 出力先
	 *      strVal      = 出力対象（`style`がliteral/foldedであること）
	 *      indent      = インデント文字列
	 *      newline     = 改行文字列
	 *      indentLevel = 現在のインデントレベル（内容は`indentLevel + 1`で出力）
	 */
	void putYamlBlockScalarImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlString) strVal,
		in char[] indent, in char[] newline, size_t indentLevel) const @safe
	{
		put(dst, strVal.style == ScalarStyle.literal ? "|" : ">");
		final switch (strVal.chomping)
		{
		case ChompingIndicator.clip:
			break;
		case ChompingIndicator.strip:
			put(dst, "-");
			break;
		case ChompingIndicator.keep:
			put(dst, "+");
			break;
		}
		put(dst, newline);
		
		const(char)[] content = strVal.value[];
		if (content.length == 0)
			return;
		
		size_t trailingNl;
		while (trailingNl < content.length && content[$ - 1 - trailingNl] == '\n')
			trailingNl++;
		auto body_ = content[0 .. $ - trailingNl];
		
		size_t start;
		for (size_t i; i <= body_.length; i++)
		{
			if (i < body_.length && body_[i] != '\n')
				continue;
			auto ln = body_[start .. i];
			if (ln.length > 0)
			{
				put(dst, indent.repeat(indentLevel + 1));
				put(dst, ln);
			}
			put(dst, newline);
			start = i + 1;
		}
		foreach (_; 0 .. (trailingNl > 0 ? trailingNl - 1 : 0))
			put(dst, newline);
	}
	
	/***************************************************************************
	 * 文字列スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * 
	 * `raw`が非空であれば無条件でそのまま出力する。空の場合は`style`に応じて
	 * 再構成する。プレーンスタイル・シングルクォートスタイルで改行を含む等
	 * 安全に出力できない内容の場合は、値を破壊しないようダブルクォートへ
	 * 自動的にフォールバックする。`escapeNonAscii`は`raw`が空でダブル
	 * クォートとして出力する場合にのみ影響する（`raw`優先時・plain/
	 * シングルクォートで安全に出力できる場合は素通しする）。
	 * Params:
	 *      dst            = 出力先
	 *      strVal         = 出力対象
	 *      indent         = インデント文字列（ブロックスカラーで使用）
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル（ブロックスカラーで使用）
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlStringImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlString) strVal,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (strVal.raw.length > 0)
		{
			put(dst, strVal.raw[]);
			return;
		}
		final switch (strVal.style)
		{
		case ScalarStyle.plain:
			if (isSafePlainScalarContentImpl(strVal.value[]))
			{
				put(dst, strVal.value[]);
			}
			else
			{
				put(dst, '"');
				putYamlDoubleQuotedContentImpl(dst, strVal.value[], escapeNonAscii);
				put(dst, '"');
			}
			break;
		case ScalarStyle.singleQuoted:
			if (strVal.value[].canFind('\n'))
			{
				put(dst, '"');
				putYamlDoubleQuotedContentImpl(dst, strVal.value[], escapeNonAscii);
				put(dst, '"');
			}
			else
			{
				put(dst, '\'');
				foreach (c; strVal.value[])
				{
					if (c == '\'')
						put(dst, "''");
					else
						put(dst, c);
				}
				put(dst, '\'');
			}
			break;
		case ScalarStyle.doubleQuoted:
			put(dst, '"');
			putYamlDoubleQuotedContentImpl(dst, strVal.value[], escapeNonAscii);
			put(dst, '"');
			break;
		case ScalarStyle.literal:
		case ScalarStyle.folded:
			putYamlBlockScalarImpl(dst, strVal, indent, newline, indentLevel);
			break;
		}
	}
	
	/***************************************************************************
	 * 符号付き整数スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * Params:
	 *      dst    = 出力先
	 *      intVal = 出力対象
	 */
	void putYamlIntegerImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlInteger) intVal) const @safe
	{
		if (intVal.raw.length > 0)
		{
			put(dst, intVal.raw[]);
			return;
		}
		final switch (intVal.base)
		{
		case IntegerBase.decimal:
			if (intVal.positiveSign)
				formattedWrite(dst, "%+d", intVal.value);
			else
				formattedWrite(dst, "%d", intVal.value);
			break;
		case IntegerBase.hex:
			if (intVal.value < 0)
				put(dst, "-");
			else if (intVal.positiveSign)
				put(dst, "+");
			formattedWrite(dst, "0x%x", absULongImpl(intVal.value));
			break;
		case IntegerBase.octal:
			if (intVal.value < 0)
				put(dst, "-");
			else if (intVal.positiveSign)
				put(dst, "+");
			formattedWrite(dst, "0o%o", absULongImpl(intVal.value));
			break;
		case IntegerBase.binary:
			if (intVal.value < 0)
				put(dst, "-");
			else if (intVal.positiveSign)
				put(dst, "+");
			formattedWrite(dst, "0b%b", absULongImpl(intVal.value));
			break;
		}
	}
	
	/***************************************************************************
	 * 符号なし整数スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * Params:
	 *      dst    = 出力先
	 *      intVal = 出力対象
	 */
	void putYamlUIntegerImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlUInteger) intVal) const @safe
	{
		if (intVal.raw.length > 0)
		{
			put(dst, intVal.raw[]);
			return;
		}
		if (intVal.positiveSign)
			put(dst, "+");
		final switch (intVal.base)
		{
		case IntegerBase.decimal:
			formattedWrite(dst, "%d", intVal.value);
			break;
		case IntegerBase.hex:
			formattedWrite(dst, "0x%x", intVal.value);
			break;
		case IntegerBase.octal:
			formattedWrite(dst, "0o%o", intVal.value);
			break;
		case IntegerBase.binary:
			formattedWrite(dst, "0b%b", intVal.value);
			break;
		}
	}
	
	/***************************************************************************
	 * 浮動小数点数スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * 
	 * 無限大・NaNは1.2 Core Schemaの表記（`.inf`/`-.inf`/`.nan`）で出力する。
	 * `withExponent && precision != 0`の場合は、小数点を含む書式文字列を
	 * 明示的に組み立てて`format()`に渡すことで、指数表記でも指定された
	 * precisionが正しく反映されるようにしている。
	 * Params:
	 *      dst   = 出力先
	 *      fpVal = 出力対象
	 */
	void putYamlFloatingPointImpl(OutputRange)(ref OutputRange dst,
		ref const(YamlValue.YamlFloatingPoint) fpVal) const @safe
	{
		import std.math : isNaN, isInfinity;
		
		if (fpVal.raw.length > 0)
		{
			put(dst, fpVal.raw[]);
			return;
		}
		if (isNaN(fpVal.value))
		{
			put(dst, ".nan");
			return;
		}
		if (isInfinity(fpVal.value))
		{
			if (fpVal.value < 0)
			{
				put(dst, "-.inf");
			}
			else
			{
				if (fpVal.positiveSign)
					put(dst, "+");
				put(dst, ".inf");
			}
			return;
		}
		
		char[64] buf;
		if (fpVal.withExponent)
		{
			if (fpVal.precision == 0)
			{
				auto valStrs = sformat(buf[], fpVal.positiveSign ? "%+e" : "%e", fpVal.value).split("e");
				assert(valStrs.length == 2 && valStrs[1].length > 2);
				formattedWrite(dst, "%se%c%s",
					valStrs[0].stripRight("0"),
					valStrs[1][0],
					valStrs[1][1 .. $].stripLeft("0"));
			}
			else
			{
				auto fmt = sformat(buf[], fpVal.positiveSign ? "%%+.%de" : "%%.%de", fpVal.precision);
				auto valStrs = sformat(buf[], fmt, fpVal.value).split("e");
				assert(valStrs.length == 2 && valStrs[1].length > 2);
				formattedWrite(dst, "%se%c%s",
					valStrs[0],
					valStrs[1][0],
					valStrs[1][1 .. $].stripLeft("0"));
			}
		}
		else
		{
			if (fpVal.precision == 0)
			{
				auto valStr = sformat(buf[], fpVal.positiveSign ? "%+f" : "%f", fpVal.value).stripRight("0");
				if (fpVal.leadingDecimalPoint && valStr.startsWith("0."))
					put(dst, valStr[1 .. $]);
				else
					put(dst, valStr);
				if (fpVal.tailingDecimalPoint && !valStr.canFind('.'))
					put(dst, ".");
				if (!fpVal.tailingDecimalPoint && valStr[$ - 1] == '.')
					put(dst, "0");
			}
			else
			{
				auto fmt = fpVal.positiveSign ? sformat(buf[], "%%+.%df", fpVal.precision)
					: sformat(buf[], "%%.%df", fpVal.precision);
				auto valStr = sformat(buf[], fmt, fpVal.value);
				if (fpVal.leadingDecimalPoint && valStr.startsWith("0."))
					put(dst, valStr[1 .. $]);
				else
					put(dst, valStr);
				if (fpVal.tailingDecimalPoint && !valStr.canFind('.'))
					put(dst, ".");
			}
		}
	}
	
	/***************************************************************************
	 * 真偽値スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * 
	 * `raw`が空の場合は1.2 Core Schema既定の`true`/`false`(小文字)で出力する。
	 * Params:
	 *      dst     = 出力先
	 *      boolVal = 出力対象
	 */
	void putYamlBooleanImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlBoolean) boolVal) const @safe
	{
		if (boolVal.raw.length > 0)
		{
			put(dst, boolVal.raw[]);
			return;
		}
		put(dst, boolVal.value ? "true" : "false");
	}
	
	/***************************************************************************
	 * null スカラーを出力する（rawテキスト優先方式。raw文字列が空でなければそれを優先してそのまま出力する）
	 * 
	 * `raw`が空の場合は1.2 Core Schema既定の`null`で出力する。
	 * Params:
	 *      dst     = 出力先
	 *      nullVal = 出力対象
	 */
	void putYamlNullImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlNull) nullVal) const @safe
	{
		if (nullVal.raw.length > 0)
		{
			put(dst, nullVal.raw[]);
			return;
		}
		put(dst, "null");
	}
	
	// ==========================================================================
	// MARK: - - Stringify (comment)
	// ==========================================================================
	// コメント出力（leading/trailing/dangling）
	
	/***************************************************************************
	 * コメント配列を「各行`# text`をそれ自身の行として出力する」形で出力する
	 * 
	 * 先頭付きコメント（`_comments`。末尾の1件が`TrailingComment`である場合は
	 * 同一行末コメントなのでここではスキップし、`putYamlTrailingCommentImpl`が
	 * 担当する）と、コレクションの`trailingComments`（ぶら下がりコメント）
	 * の両方の出力に共用する。`#`直後の文字列は
	 * `parseCommentTextImpl`が`#`の直後から改行直前までを一切加工せず
	 * 保持しているため、`"#" ~ value`だけで元のコメント行を正確に再現できる。
	 * Params:
	 *      dst         = 出力先
	 *      comments    = 出力対象のコメント配列
	 *      indent      = インデント文字列
	 *      newline     = 改行文字列
	 *      indentLevel = コメント行自身のインデントレベル
	 */
	void putYamlCommentLinesImpl(OutputRange)(ref OutputRange dst, ref const(Array!(YamlValue.Comment)) comments,
		in char[] indent, in char[] newline, size_t indentLevel) const @safe
	{
		foreach (ref c; comments[])
		{
			c.match!(
				(ref const(YamlValue.LineComment) lc)
				{
					put(dst, indent.repeat(indentLevel));
					put(dst, "#");
					put(dst, lc.value[]);
					put(dst, newline);
				},
				(ref const(YamlValue.TrailingComment) tc) {}
			);
		}
	}
	
	/***************************************************************************
	 * 値と同一行に続く末尾コメント（`key: value # comment`の`# comment`部分）を
	 * 出力する
	 * 
	 * `comments`の末尾の1件が`TrailingComment`である場合のみ出力する
	 * （`isTrailingComment`の前提と同じく、`TrailingComment`は配列の
	 * 最後尾にしか現れない）。値と`#`の間の空白は`expectEndOfLineImpl`が
	 * 元の個数を保持せず読み飛ばすため、常に半角スペース1つに正規化して
	 * 出力する。
	 * Params:
	 *      dst      = 出力先
	 *      comments = 出力対象のコメント配列
	 */
	void putYamlTrailingCommentImpl(OutputRange)(ref OutputRange dst,
		ref const(Array!(YamlValue.Comment)) comments) const @safe
	{
		if (comments.length == 0)
			return;
		comments[$ - 1].match!(
			(ref const(YamlValue.TrailingComment) tc)
			{
				put(dst, " #");
				put(dst, tc.value[]);
			},
			(ref const(YamlValue.LineComment) lc) {}
		);
	}
	
	// ==========================================================================
	// MARK: - - Stringify (flow collection)
	// ==========================================================================
	// flowコレクション出力
	
	/***************************************************************************
	 * マッピングキーを出力する
	 * 
	 * キーには`raw`フィールドが無いため、常に`style`から再構成する。
	 * plain/シングルクォートで安全に出力できない内容(改行を含む等)は
	 * ダブルクォートへ自動的にフォールバックする(`putYamlStringImpl`の
	 * 対応する分岐と同じ方針)。キーはliteral/foldedスタイルを取り得ない前提とする。
	 * Params:
	 *      dst            = 出力先
	 *      key            = 出力対象のキー
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlKeyImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlKey) key,
		bool escapeNonAscii = false) const @safe
	{
		final switch (key.style)
		{
		case ScalarStyle.plain:
			if (isSafePlainScalarContentImpl(key.value[]))
			{
				put(dst, key.value[]);
			}
			else
			{
				put(dst, '"');
				putYamlDoubleQuotedContentImpl(dst, key.value[], escapeNonAscii);
				put(dst, '"');
			}
			break;
		case ScalarStyle.singleQuoted:
			if (key.value[].canFind('\n'))
			{
				put(dst, '"');
				putYamlDoubleQuotedContentImpl(dst, key.value[], escapeNonAscii);
				put(dst, '"');
			}
			else
			{
				put(dst, '\'');
				foreach (c; key.value[])
				{
					if (c == '\'')
						put(dst, "''");
					else
						put(dst, c);
				}
				put(dst, '\'');
			}
			break;
		case ScalarStyle.doubleQuoted:
			put(dst, '"');
			putYamlDoubleQuotedContentImpl(dst, key.value[], escapeNonAscii);
			put(dst, '"');
			break;
		case ScalarStyle.literal:
		case ScalarStyle.folded:
			assert(0, "Mapping keys must not use literal/folded style");
		}
	}
	
	/***************************************************************************
	 * アンカー・タグの前置トークン（`&name`・`!tag`）を出力する
	 * 
	 * アンカーが設定されていれば`&name`を、タグが設定されていれば続けて
	 * (アンカーがあれば半角スペース区切りで)`!tag`を出力する。末尾には
	 * 空白を付与しない(値そのものとの区切りは呼び出し元の責務とする)。
	 * 
	 * タグについては`_tag`の格納形式に2通りある点に注意する:
	 * パーサー(`parseTagImpl`)が設定した場合は`!`自体を含む生のトークン
	 * (`!mytag`/`!!str`/`!<...>`等)がそのまま格納されるが、`tag()`UDA
	 * (`setTag()`経由)は`!!`プレフィックスを除いた名称のみを格納する
	 * 契約になっている。そのため、格納値が`!`から始まっていなければ
	 * `!!`を補って出力する。
	 * Params:
	 *      dst   = 出力先
	 *      value = 出力対象(そのノード自身の`_anchor`/`_tag`を参照する)
	 */
	void putYamlAnchorTagPrefixImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue) value) const @safe
	{
		if (!value._anchor.isNull)
		{
			put(dst, "&");
			put(dst, value._anchor.get[]);
		}
		if (!value._tag.isNull)
		{
			if (!value._anchor.isNull)
				put(dst, " ");
			auto t = value._tag.get[];
			if (t.length == 0 || t[0] != '!')
				put(dst, "!!");
			put(dst, t);
		}
	}
	
	/***************************************************************************
	 * flowコンテキスト内の1ノード(スカラー・エイリアス・ネストしたflow
	 * コレクション)を出力する
	 * 
	 * YAML文法上、flowコレクションの子要素はflowスカラー(plain/quoted)か
	 * ネストしたflowコレクションのみであり、ブロックスカラー
	 * (literal/folded)は出現し得ない(`parseFlowNodeImpl`もこの2種類しか
	 * 生成しない)。ネストしたsequence/mappingは、格納されている`style`の
	 * 値に関わらず常にflowスタイルとして出力する(flow文脈内にblock
	 * スタイルの子を置くことはYAML文法上不可能なため、位置がスタイルより
	 * 優先される)。本関数自体は`value`自身のleading/trailingコメントを
	 * 出力しない。呼び出し元(`putYamlFlowSequenceImpl`/
	 * `putYamlFlowMappingImpl`/`putYamlBlockChildImpl`)が各要素の前後で
	 * `putYamlCommentLinesImpl`/`putYamlTrailingCommentImpl`を呼び出す
	 * 構成になっている。アンカー(`&name`)・タグ(`!tag`)は
	 * `putYamlAnchorTagPrefixImpl`により本関数の先頭で共通処理として
	 * 出力する。
	 * Params:
	 *      dst            = 出力先
	 *      value          = 出力対象
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlFlowNodeImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue) value,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (!value._anchor.isNull || !value._tag.isNull)
		{
			putYamlAnchorTagPrefixImpl(dst, value);
			put(dst, " ");
		}
		final switch (value.type)
		{
		case YamlType.undefined:
			break; // 無視(シリアライズ側のスキップマーカー用途を想定)
		case YamlType.alias_:
			put(dst, "*");
			put(dst, value.asAlias.value[]);
			break;
		case YamlType.string:
			putYamlStringImpl(dst, value.asString, indent, newline, indentLevel, escapeNonAscii);
			break;
		case YamlType.integer:
			putYamlIntegerImpl(dst, value.asInteger);
			break;
		case YamlType.uinteger:
			putYamlUIntegerImpl(dst, value.asUInteger);
			break;
		case YamlType.floating:
			putYamlFloatingPointImpl(dst, value.asFloatingPoint);
			break;
		case YamlType.boolean:
			putYamlBooleanImpl(dst, value.asBoolean);
			break;
		case YamlType.nullfied:
			putYamlNullImpl(dst, value.asNull);
			break;
		case YamlType.sequence:
			putYamlFlowSequenceImpl(dst, value.asSequence, indent, newline, indentLevel, escapeNonAscii);
			break;
		case YamlType.mapping:
			putYamlFlowMappingImpl(dst, value.asMapping, indent, newline, indentLevel, escapeNonAscii);
			break;
		}
	}
	
	/***************************************************************************
	 * flowシーケンス(`[...]`)を出力する
	 * 
	 * `singleLine`が`true`の場合は`[a, b, c]`のように1行で出力し、`false`の
	 * 場合は要素ごとに改行して`indentLevel + 1`でインデントする。
	 * いずれも`trailingComma`が`true`なら末尾要素の後にも`,`を出力する。
	 * 空シーケンスは常に`[]`と出力する(この2つのフラグに関わらず)。
	 * `singleLine == false`の場合のみ、各要素のleading/trailingコメントと
	 * 末尾のぶら下がりコメント(`trailingComments`)を出力する。
	 * `singleLine == true`は改行を含まない1行出力である以上、要素間に
	 * コメント行を挟むことは構文上できないため、コメントは意図的に
	 * 出力しない(パーサも改行を検出した時点で`singleLine`を`false`に
	 * 倒すため、この2つが両立するデータはパース結果としては生じない)。
	 * Params:
	 *      dst            = 出力先
	 *      seq            = 出力対象
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlFlowSequenceImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlSequence) seq,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (seq.value.length == 0)
		{
			put(dst, "[]");
			return;
		}
		put(dst, "[");
		if (seq.singleLine)
		{
			foreach (i, ref elem; seq.value)
			{
				if (i > 0)
					put(dst, ", ");
				putYamlFlowNodeImpl(dst, elem, indent, newline, indentLevel, escapeNonAscii);
			}
			if (seq.trailingComma)
				put(dst, ",");
		}
		else
		{
			put(dst, newline);
			foreach (i, ref elem; seq.value)
			{
				putYamlCommentLinesImpl(dst, elem._comments, indent, newline, indentLevel + 1);
				put(dst, indent.repeat(indentLevel + 1));
				putYamlFlowNodeImpl(dst, elem, indent, newline, indentLevel + 1, escapeNonAscii);
				if (i + 1 != seq.value.length || seq.trailingComma)
					put(dst, ",");
				putYamlTrailingCommentImpl(dst, elem._comments);
				put(dst, newline);
			}
			putYamlCommentLinesImpl(dst, seq.trailingComments, indent, newline, indentLevel + 1);
			put(dst, indent.repeat(indentLevel));
		}
		put(dst, "]");
	}
	
	/***************************************************************************
	 * flowマッピング(`{...}`)を出力する
	 * 
	 * `singleLine`が`true`の場合は`{a: 1, b: 2}`のように1行で出力し、
	 * `false`の場合はエントリごとに改行して`indentLevel + 1`でインデントする。
	 * いずれも`trailingComma`が`true`なら末尾エントリの後にも`,`を出力する。
	 * 空マッピングは常に`{}`と出力する(この2つのフラグに関わらず)。値の型が
	 * `YamlType.undefined`のエントリは出力をスキップする(シリアライズ側の
	 * スキップマーカー用途を想定)。`singleLine == false`の場合のみ、各
	 * エントリのleading/trailingコメントと末尾のぶら下がりコメント
	 * (`trailingComments`)を出力する。理由は`putYamlFlowSequenceImpl`と
	 * 同じ(1行出力とは両立し得ないため)。
	 * Params:
	 *      dst            = 出力先
	 *      mapping        = 出力対象
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlFlowMappingImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlMapping) mapping,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (mapping.value.length == 0)
		{
			put(dst, "{}");
			return;
		}
		put(dst, "{");
		if (mapping.singleLine)
		{
			bool first = true;
			foreach (ref itm; mapping.value.byKeyValue)
			{
				if (itm.value.type == YamlType.undefined)
					continue;
				if (!first)
					put(dst, ", ");
				first = false;
				putYamlKeyImpl(dst, itm.key, escapeNonAscii);
				put(dst, ": ");
				putYamlFlowNodeImpl(dst, itm.value, indent, newline, indentLevel, escapeNonAscii);
			}
			if (mapping.trailingComma)
				put(dst, ",");
		}
		else
		{
			put(dst, newline);
			immutable n = mapping.value.length;
			foreach (i, ref itm; mapping.value.byKeyValue)
			{
				if (itm.value.type == YamlType.undefined)
					continue;
				putYamlCommentLinesImpl(dst, itm.value._comments, indent, newline, indentLevel + 1);
				put(dst, indent.repeat(indentLevel + 1));
				putYamlKeyImpl(dst, itm.key, escapeNonAscii);
				put(dst, ": ");
				putYamlFlowNodeImpl(dst, itm.value, indent, newline, indentLevel + 1, escapeNonAscii);
				if (i + 1 != n || mapping.trailingComma)
					put(dst, ",");
				putYamlTrailingCommentImpl(dst, itm.value._comments);
				put(dst, newline);
			}
			putYamlCommentLinesImpl(dst, mapping.trailingComments, indent, newline, indentLevel + 1);
			put(dst, indent.repeat(indentLevel));
		}
		put(dst, "}");
	}
	
	// ==========================================================================
	// MARK: - - Stringify (block collection)
	// ==========================================================================
	// blockコレクション出力（インデント計算・ネスト）
	
	/***************************************************************************
	 * 値がblock文脈で「改行してネスト表示すべき」コレクションかどうかを判定する
	 * 
	 * 以下のいずれかに該当する場合は`false`（＝プレフィックス`- `/`key: `と
	 * 同一行にインライン出力すべき）を返す:
	 * - スカラー・エイリアス・undefinedである
	 * - コレクションだが`style`がflowである（flow文脈の子は常にflowのまま
	 *   出力される。その対になる、block文脈での判定）
	 * - コレクションだが要素数が0である（空コレクションはblock記法では
	 *   表現できない仕様上の制約のため、常にflowの`[]`/`{}`で表現する）
	 * Params:
	 *      value = 判定対象
	 * Returns:
	 *      改行してネスト表示すべきなら`true`
	 */
	bool isBlockNestedCollectionImpl(ref const(YamlValue) value) const pure nothrow @nogc @safe
	{
		if (value.type == YamlType.sequence)
			return value.asSequence.style == CollectionStyle.block && value.asSequence.value.length > 0;
		if (value.type == YamlType.mapping)
			return value.asMapping.style == CollectionStyle.block && value.asMapping.value.length > 0;
		return false;
	}
	
	/***************************************************************************
	 * blockシーケンス項目・blockマッピングエントリに共通する「値部分」を出力する
	 * 
	 * `isBlockNestedCollectionImpl`が`true`の場合は改行し、続けて`value`自身の
	 * leadingコメントを`indentLevel + 1`の位置に出力してから、
	 * `indentLevel + 1`でネストしたblockコレクションとして出力する
	 * （`-`/`key:`自身の行には値を何も残さない。行末に不要な空白を
	 * 残さないための意図的な分岐）。leadingコメントをここで（ネスト本体の
	 * 直前に）出力するのは、値自身の出力が実質的にここから始まるためで
	 * ある（`-`/`key:`の行はあくまで親側のプレフィックスであり、値
	 * 自身の出力ではない）。
	 * そうでない場合はプレフィックス（`-`/`key:`）と同一行に半角スペース1つを
	 * 挟んでインライン出力する（スカラーは各`putYamlXxxImpl`、flow/
	 * 空コレクション・エイリアスは`putYamlFlowNodeImpl`をそのまま再利用する）。
	 * この場合、`value`自身のleadingコメントは値の出力が`-`/`key:`と
	 * 同一行から始まる以上、`-`/`key:`行より前にしか置けないため、
	 * この関数を呼び出す前に呼び出し元（`putYamlBlockSequenceImpl`/
	 * `putYamlBlockMappingImpl`）が出力済みである前提とする。インライン
	 * 出力した場合のみ、続けて`value`自身の末尾コメント
	 * （`putYamlTrailingCommentImpl`）を出力する（ネスト側の分岐では
	 * `-`/`key:`の行に他の内容が残らないため、末尾コメントを出す余地が
	 * そもそも無い）。アンカー・タグは、ネスト出力の場合はこの関数自身が
	 * 改行の直前に、インライン出力の場合は`putYamlFlowNodeImpl`が
	 * それぞれ出力する。
	 * Params:
	 *      dst            = 出力先
	 *      value          = 出力対象
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = プレフィックス（`-`/`key:`）自身のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlBlockChildImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue) value,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (isBlockNestedCollectionImpl(value))
		{
			if (!value._anchor.isNull || !value._tag.isNull)
			{
				put(dst, " ");
				putYamlAnchorTagPrefixImpl(dst, value);
			}
			put(dst, newline);
			putYamlCommentLinesImpl(dst, value._comments, indent, newline, indentLevel + 1);
			final switch (value.type)
			{
			case YamlType.sequence:
				putYamlBlockSequenceImpl(dst, value.asSequence, indent, newline, indentLevel + 1, escapeNonAscii);
				break;
			case YamlType.mapping:
				putYamlBlockMappingImpl(dst, value.asMapping, indent, newline, indentLevel + 1, escapeNonAscii);
				break;
			case YamlType.undefined:
			case YamlType.alias_:
			case YamlType.string:
			case YamlType.integer:
			case YamlType.uinteger:
			case YamlType.floating:
			case YamlType.boolean:
			case YamlType.nullfied:
				assert(0, "isBlockNestedCollectionImpl guarantees sequence/mapping here");
			}
		}
		else
		{
			put(dst, " ");
			putYamlFlowNodeImpl(dst, value, indent, newline, indentLevel, escapeNonAscii);
			putYamlTrailingCommentImpl(dst, value._comments);
			// literal/foldedブロックスカラーは`putYamlBlockScalarImpl`が
			// 既に末尾の改行(ヘッダ行の改行、および内容行それぞれの改行)を
			// 出力済みのため、ここで追加の改行を出すと空行が二重に生じてしまう。
			immutable isBlockScalarValue = value.type == YamlType.string
				&& (value.asString.style == ScalarStyle.literal
					|| value.asString.style == ScalarStyle.folded);
			if (!isBlockScalarValue)
				put(dst, newline);
		}
	}
	
	/***************************************************************************
	 * blockシーケンス（`- item`）を出力する
	 * 
	 * 各項目は`indentLevel`の位置に`-`を出力し、値部分は`putYamlBlockChildImpl`に
	 * 委ねる。項目のleadingコメントの出力位置は、値がインライン出力される
	 * 場合（スカラー・flow・空コレクション・エイリアス）は`indentLevel`の
	 * 位置に`-`より前として出力し、値がネストしたblockコレクションとして
	 * 改行して出力される場合は`putYamlBlockChildImpl`側で改行直後・
	 * ネスト本体より前（`indentLevel + 1`の位置）に出力する。これは、
	 * leadingコメントが常に「値自身の出力が始まる直前の行」に位置する
	 * べきという方針に基づく（値の出力開始位置は、インラインなら`-`と
	 * 同じ行、ネストなら次の行以降のネスト本体の先頭になるため）。
	 * 全項目の後には`trailingComments`（ぶら下がりコメント）を
	 * `indentLevel`の位置に出力する。空シーケンスは
	 * 呼び出し元（`putYamlBlockChildImpl`/`putYamlBlockNodeImpl`）が
	 * `isBlockNestedCollectionImpl`で弾くため、本関数が空シーケンスを
	 * 受け取ることはない前提とする。
	 * Params:
	 *      dst            = 出力先
	 *      seq            = 出力対象（空でないこと）
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlBlockSequenceImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlSequence) seq,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		foreach (ref elem; seq.value)
		{
			if (!isBlockNestedCollectionImpl(elem))
				putYamlCommentLinesImpl(dst, elem._comments, indent, newline, indentLevel);
			put(dst, indent.repeat(indentLevel));
			put(dst, "-");
			putYamlBlockChildImpl(dst, elem, indent, newline, indentLevel, escapeNonAscii);
		}
		putYamlCommentLinesImpl(dst, seq.trailingComments, indent, newline, indentLevel);
	}
	
	/***************************************************************************
	 * blockマッピング（`key: value`）を出力する
	 * 
	 * 各エントリは`indentLevel`の位置にキーを出力し、値部分は
	 * `putYamlBlockChildImpl`に委ねる。値の型が`YamlType.undefined`の
	 * エントリは出力をスキップする（`putYamlFlowMappingImpl`と同じ方針）。
	 * エントリのleadingコメントの出力位置は`putYamlBlockSequenceImpl`と
	 * 同じ方針（インラインなら`key:`より前を`indentLevel`、ネストなら
	 * `putYamlBlockChildImpl`側で`indentLevel + 1`）。全エントリの後には
	 * `trailingComments`（ぶら下がりコメント）を`indentLevel`の位置に
	 * 出力する。空マッピングは呼び出し元が
	 * `isBlockNestedCollectionImpl`で弾くため、本関数が空マッピングを
	 * 受け取ることはない前提とする。
	 * Params:
	 *      dst            = 出力先
	 *      mapping        = 出力対象（空でないこと）
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlBlockMappingImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue.YamlMapping) mapping,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		foreach (ref itm; mapping.value.byKeyValue)
		{
			if (itm.value.type == YamlType.undefined)
				continue;
			if (!isBlockNestedCollectionImpl(itm.value))
				putYamlCommentLinesImpl(dst, itm.value._comments, indent, newline, indentLevel);
			put(dst, indent.repeat(indentLevel));
			putYamlKeyImpl(dst, itm.key, escapeNonAscii);
			put(dst, ":");
			putYamlBlockChildImpl(dst, itm.value, indent, newline, indentLevel, escapeNonAscii);
		}
		putYamlCommentLinesImpl(dst, mapping.trailingComments, indent, newline, indentLevel);
	}
	
	/***************************************************************************
	 * blockノード（スカラー・エイリアス・sequence・mapping）を1つ出力する
	 * 
	 * ドキュメントルート等、プレフィックス（`-`/`key:`）を伴わない位置で使う
	 * トップレベルディスパッチャ。`isBlockNestedCollectionImpl`に応じて
	 * block出力（`putYamlBlockSequenceImpl`/`putYamlBlockMappingImpl`）と
	 * インライン出力（`putYamlFlowNodeImpl`。スカラー・flow・空コレクション・
	 * エイリアス用）のいずれかへディスパッチする（`toPrettyString`から
	 * 呼ばれる想定）。
	 * Params:
	 *      dst            = 出力先
	 *      value          = 出力対象
	 *      indent         = インデント文字列
	 *      newline        = 改行文字列
	 *      indentLevel    = 現在のインデントレベル
	 *      escapeNonAscii = ASCII範囲外をエスケープするか（既定: `false`）
	 */
	void putYamlBlockNodeImpl(OutputRange)(ref OutputRange dst, ref const(YamlValue) value,
		in char[] indent, in char[] newline, size_t indentLevel, bool escapeNonAscii = false) const @safe
	{
		if (isBlockNestedCollectionImpl(value))
		{
			if (!value._anchor.isNull || !value._tag.isNull)
			{
				putYamlAnchorTagPrefixImpl(dst, value);
				put(dst, newline);
			}
			final switch (value.type)
			{
			case YamlType.sequence:
				putYamlBlockSequenceImpl(dst, value.asSequence, indent, newline, indentLevel, escapeNonAscii);
				break;
			case YamlType.mapping:
				putYamlBlockMappingImpl(dst, value.asMapping, indent, newline, indentLevel, escapeNonAscii);
				break;
			case YamlType.undefined:
			case YamlType.alias_:
			case YamlType.string:
			case YamlType.integer:
			case YamlType.uinteger:
			case YamlType.floating:
			case YamlType.boolean:
			case YamlType.nullfied:
				assert(0, "isBlockNestedCollectionImpl guarantees sequence/mapping here");
			}
		}
		else
		{
			putYamlFlowNodeImpl(dst, value, indent, newline, indentLevel, escapeNonAscii);
		}
	}
	
public:
	// ==========================================================================
	// MARK: - - Public API (parse())
	// ==========================================================================
	
	/***************************************************************************
	 * YAML文字列をパースし、ルートノードを返す
	 * 
	 * 単一ドキュメントのみをサポートする。以下の場合は
	 * `YamlParseException`を送出する:
	 * - 複数ドキュメント区切り（行頭`---`/`...`）またはディレクティブ
	 *   （`%`で始まる行）が入力中のどこかに出現した場合
	 * - ストリーム先頭以外の位置にBOM（`\uFEFF`）が出現した場合
	 * - ルートノードのパース後に、空行・コメント以外の内容が残っている場合
	 * 
	 * `anchorTable`・保留コメントキューは呼び出しのたびにクリアするため、
	 * 同一の`YamlBuilder`インスタンスを複数回のパースに再利用しても
	 * 前回の状態が混入することはない。
	 * Params:
	 *      src = パース対象のYAML文字列
	 * Returns:
	 *      パース結果のルートノード
	 * Throws:
	 *      構文エラー・非対応構文検出時に `YamlParseException`
	 */
	YamlValue parse(in char[] src) @safe
	{
		_anchorTable = allocDic!(string, YamlValue);
		_pendingComments = allocAry!PendingComment;
		
		size_t line = 1;
		size_t col = 1;
		size_t index = skipBOMImpl(src);
		
		immutable bomPos = src[index .. $].indexOf("\uFEFF");
		if (bomPos >= 0)
		{
			throw new YamlParseException(
				"BOM (U+FEFF) is only allowed at the start of the stream",
				index + bomPos, line, col);
		}
		
		checkNoDocumentMarkerImpl(src[index .. $], index, line, col);
		
		YamlValue root;
		immutable consumed = parseBlockNodeImpl(root, src[index .. $], line, col, 0);
		index += consumed;
		
		index += skipBlankAndCommentLinesImpl(src[index .. $], line, col);
		
		if (index < src.length)
		{
			checkNoDocumentMarkerImpl(src[index .. $], index, line, col);
			throw new YamlParseException(
				"Unexpected trailing content after document", index, line, col);
		}
		
		return root;
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		
		// 基本的なマッピング・シーケンス・スカラーのパース
		auto v = builder.parse("name: Alice\nage: 20\ntags:\n  - a\n  - b\n");
		assert(v.asMapping["name"].asString.value[] == "Alice");
		assert(v.asMapping["age"].asInteger.value == 20);
		assert(v.asMapping["tags"].asSequence.value.length == 2);
		
		// パースエラー時はYamlParseExceptionを送出する
		import std.exception : collectException;
		auto e = collectException!YamlParseException(builder.parse("key: 'unterminated"));
		assert(e !is null);
	}
	
	// ==========================================================================
	// MARK: - - Stringify (public entry point)
	// ==========================================================================
	
	/***************************************************************************
	 * pretty-print整形オプション
	 * 
	 * `defaultStyle`は`toPrettyString`自身からは参照しない。既存ノードは
	 * （`parse()`由来であれ`make()`由来であれ）常に自身の`style`フィールドを
	 * 明示的に持つため、出力時に「未設定」を区別してこのフィールドで補う
	 * 必要が無いためである。将来、新規構築時の既定スタイル決定に利用する
	 * ことを想定してフィールドのみ用意している。
	 */
	static struct YamlPrettyPrintOptions
	{
		/// インデント文字列（既定: スペース2つ）
		string indent = "  ";
		/// 改行文字列（既定: LF）
		string newline = "\n";
		/// ASCII範囲外をエスケープするか（既定: `false`）
		bool escapeNonAscii = false;
		/// 既定のコレクションスタイル（現時点では未使用。上記doc参照）
		CollectionStyle defaultStyle = CollectionStyle.block;
	}
	
	/***************************************************************************
	 * YAML値をpretty-print形式で出力する
	 * 
	 * ルートノード自身のleading/trailingコメントも出力する
	 * （`putYamlCommentLinesImpl`/`putYamlTrailingCommentImpl`をルート
	 * レベルで適用する。各`putYamlBlockXxxImpl`は「親から見た子」の
	 * コメントしか出力しないため、ルート自身のコメントを出力できるのは
	 * この最上位の`toPrettyString`だけである）。
	 * ルートの値本体は`putYamlBlockNodeImpl`に委譲し、block/flow・
	 * スカラー/コレクションの判別はそちらに任せる。末尾に改行は追加しない
	 * （block系コレクションは各エントリ自身が末尾に改行を含むため結果的に
	 * 改行で終わるが、スカラーがルートの場合は追加しない）。
	 * Params:
	 *      dst     = 出力先
	 *      value   = 出力対象
	 *      options = 整形オプション（既定値: `YamlPrettyPrintOptions.init`）
	 */
	void toPrettyString(OutputRange)(ref OutputRange dst, ref const(YamlValue) value,
		YamlPrettyPrintOptions options = YamlPrettyPrintOptions.init) const @safe
	{
		putYamlCommentLinesImpl(dst, value._comments, options.indent, options.newline, 0);
		putYamlBlockNodeImpl(dst, value, options.indent, options.newline, 0, options.escapeNonAscii);
		putYamlTrailingCommentImpl(dst, value._comments);
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		auto v = builder.parse("name: Alice\naddress:\n  city: Tokyo\n");
		
		auto app = appender!(char[])();
		builder.toPrettyString(app, v);
		assert(app.data == "name: Alice\naddress:\n  city: Tokyo\n");
		
		// インデント幅などは YamlOptions で変更できる
		app.shrinkTo(0);
		builder.toPrettyString(app, v, YamlOptions("    "));
		assert(app.data == "name: Alice\naddress:\n    city: Tokyo\n");
	}
	
private:
	// ==========================================================================
	// MARK: - - Update
	// ==========================================================================
	// update()はフォーマットを可能な限り保持したまま値だけを更新する。
	// 具体的には、(1)数値/文字列を更新する際は`raw`フィールドを必ずクリアする、
	// (2)`dst`が`YamlAlias`の場合はエイリアスを解除して具体値に置き換える、
	// の2点をYAML固有の方針として反映する。集約型(struct)・Tuple・SumType
	// への対応はSerializerに強く依存するため、Serializer/Deserializerと
	// 合わせて後段でupdate()の公開エントリポイントに実装する。
	
	/***************************************************************************
	 * 更新用の新規値を作る
	 * 
	 * `src`が`YamlValueImpl`（既に構築済みのノード。配列/マッピングの要素と
	 * して渡ってくる）であれば`deepCopy()`で独立した複製を作る。それ以外の
	 * ネイティブなD言語の型であれば`make()`で新規構築する。前者を`make()`
	 * （単純代入）で済ませてしまうと、複製元と要素配列/連想配列のストレージを
	 * 共有してしまい独立性が壊れるため、区別が必要である。
	 */
	YamlValue cloneForUpdateImpl(T)(auto ref T src) @safe
	{
		static if (is(Unqual!T == YamlValue))
			return deepCopy(src);
		else
			return make(src);
	}
	
	/***************************************************************************
	 * `dst`のノード自体（`_comments`/`_anchor`/`_tag`/既存の`_builder`）は
	 * 保持したまま、値の実体（`_instance`）だけを`src`から新規構築した値で
	 * 丸ごと置き換える。`updateValueImpl`のmatchで型が一致しなかった場合
	 * （`dst`が未定義値・エイリアス・別のスカラー/コレクション型だった
	 * 場合を含む）のフォールバックとして使う。
	 */
	void replaceValueImpl(T)(ref YamlValue dst, auto ref T src) @trusted
	{
		auto tmp = cloneForUpdateImpl(src);
		dst._instance = tmp._instance;
		if (dst._builder is null)
			dst._builder = tmp._builder;
	}
	
	/***************************************************************************
	 * `dst`を`src`の値で更新する（`update()`の実装本体）
	 * 
	 * `dst`の現在の型が`src`に対応する型であれば、その値（`.value`）のみを
	 * 書き換え、スカラー型では`raw`もあわせてクリアする（更新後の値と元の
	 * テキスト表記が乖離しないようにするため）。対応しない型であれば
	 * `replaceValueImpl`により`_instance`ごと新規に構築し直す。`dst`が
	 * `YamlAlias`だった場合もこのmatch機構により自然に「型不一致」として
	 * 扱われ`_instance`が具体値で置き換えられるため、「エイリアスを解除して
	 * 具体値に置き換える」という`update()`の方針を特別な分岐無しに満たす
	 * （アンカー定義側や`_comments`/`_anchor`/`_tag`自体は`dst`のものを
	 * 保持するため変化しない）。
	 * 
	 * `src`が`YamlValueImpl`の場合は、`dereference()`でエイリアス連鎖を
	 * 辿った上でその中身の型に応じて再帰的に自分自身へ委譲する。この際、
	 * `src`側の書式情報（`raw`/`style`/`base`等）は使わず値のみを使う
	 * （前述の通りformatは`dst`側のものを優先して保持する方針のため）。
	 * 配列・連想配列（`Dictionary!(YamlKey, YamlValueImpl)`を含む）は
	 * 要素/キー単位で再帰的に同じ処理を適用し、`dst`側に既存のキー/
	 * インデックスがあれば更新、無ければ`cloneForUpdateImpl`で新規追加する。
	 * `src`に存在しない`dst`側のキーは削除され、`src`の完全なキー集合に
	 * 同期する。
	 */
	void updateValueImpl(T)(ref YamlValue dst, auto ref T src) @trusted
	{
		alias U = Unqual!T;
		static if (is(U == YamlValue))
		{
			src.dereference()._instance.match!(
				(ref const(YamlValue.UndefinedValue) _) { dst._instance = YamlValue.UndefinedValue.init; },
				(ref const(YamlValue.YamlAlias) _)
				{
					// dereference()済みのためここには到達しないはずだが、
					// SumType.matchの網羅性チェックのためハンドラが必要
					assert(0, "unreachable: dereference() must resolve YamlAlias");
				},
				(ref const(YamlValue.YamlString) s)        { updateValueImpl(dst, cast(string)s.value[]); },
				(ref const(YamlValue.YamlInteger) s)       { updateValueImpl(dst, s.value); },
				(ref const(YamlValue.YamlUInteger) s)      { updateValueImpl(dst, s.value); },
				(ref const(YamlValue.YamlFloatingPoint) s) { updateValueImpl(dst, s.value); },
				(ref const(YamlValue.YamlBoolean) s)       { updateValueImpl(dst, s.value); },
				(ref const(YamlValue.YamlNull) s)          { updateValueImpl(dst, null); },
				(ref const(YamlValue.YamlSequence) s)      { updateValueImpl(dst, s.value); },
				(ref const(YamlValue.YamlMapping) s)       { updateValueImpl(dst, s.value); });
		}
		else static if (is(U == string))
		{
			dst._instance.match!(
				(ref YamlValue.YamlString v) { v.value = allocStr(src); v.raw = String.init; },
				(_) { replaceValueImpl(dst, src); });
		}
		else static if (isSomeString!U)
		{
			import std.utf: toUTF8;
			updateValueImpl(dst, src.toUTF8());
		}
		else static if (isIntegral!U && isSigned!U)
		{
			dst._instance.match!(
				(ref YamlValue.YamlInteger v) { v.value = src; v.raw = String.init; },
				(_) { replaceValueImpl(dst, src); });
		}
		else static if (isIntegral!U && isUnsigned!U)
		{
			dst._instance.match!(
				(ref YamlValue.YamlUInteger v) { v.value = src; v.raw = String.init; },
				(_) { replaceValueImpl(dst, src); });
		}
		else static if (isFloatingPoint!U)
		{
			dst._instance.match!(
				(ref YamlValue.YamlFloatingPoint v) { v.value = src; v.raw = String.init; },
				(_) { replaceValueImpl(dst, src); });
		}
		else static if (isBoolean!U)
		{
			dst._instance.match!(
				(ref YamlValue.YamlBoolean v) { v.value = src; v.raw = String.init; },
				(_) { replaceValueImpl(dst, src); });
		}
		else static if (is(U == typeof(null)))
		{
			dst._instance.match!(
				(ref YamlValue.YamlNull v) { v.raw = String.init; },
				(_) { replaceValueImpl(dst, null); });
		}
		else static if (isArray!U)
		{
			dst._instance.match!(
				(ref YamlValue.YamlSequence seq)
				{
					immutable newLen = src.length;
					if (newLen < seq.value.length)
						seq.value.length = newLen;
					foreach (i, ref e; src)
					{
						if (i < seq.value.length)
							updateValueImpl(seq.value[i], e);
						else
							seq.value ~= cloneForUpdateImpl(e);
					}
				},
				(_)
				{
					auto ary = allocAry!YamlValue;
					foreach (ref e; src)
						ary ~= cloneForUpdateImpl(e);
					replaceValueImpl(dst, YamlValue.YamlSequence(ary));
				});
		}
		else static if ((isAssociativeArray!U && is(KeyType!U == string))
			|| is(U == Dictionary!(YamlKey, YamlValue)))
		{
			dst._instance.match!(
				(ref YamlValue.YamlMapping m)
				{
					auto tmp = allocDic!(YamlKey, YamlValue);
					static if (is(U == Dictionary!(YamlKey, YamlValue)))
					{
						foreach (ref srcItm; src.byKeyValue)
						{
							if (auto pv = m.value.opIn(srcItm.key))
							{
								updateValueImpl(*pv, srcItm.value);
								tmp.append(srcItm.key, *pv);
							}
							else
							{
								tmp.append(srcItm.key, deepCopy(srcItm.value));
							}
						}
					}
					else
					{
						foreach (k, ref v; src)
						{
							auto key = YamlKey(cast(String)k);
							if (auto pv = m.value.opIn(key))
							{
								updateValueImpl(*pv, v);
								tmp.append(key, *pv);
							}
							else
							{
								tmp.append(key, cloneForUpdateImpl(v));
							}
						}
					}
					m.value = tmp;
				},
				(_)
				{
					auto tmp = allocDic!(YamlKey, YamlValue);
					static if (is(U == Dictionary!(YamlKey, YamlValue)))
					{
						foreach (ref srcItm; src.byKeyValue)
							tmp.append(srcItm.key, deepCopy(srcItm.value));
					}
					else
					{
						foreach (k, ref v; src)
							tmp.append(YamlKey(cast(String)k), cloneForUpdateImpl(v));
					}
					replaceValueImpl(dst, YamlValue.YamlMapping(tmp));
				});
		}
		else
			static assert(0, "voile.yaml: update()は" ~ T.stringof ~ "型に対応していません" ~
				"(struct/Tuple/SumTypeの対応はserialize()実装後に追加予定です)");
	}
	
public:
	// ==========================================================================
	// MARK: - - Update (public entry point)
	// ==========================================================================
	
	/***************************************************************************
	 * `dst`を`src`の値でフォーマットを可能な限り保持したまま更新する
	 * 
	 * `dst`が現在保持している値と同じ種類（文字列/整数/浮動小数点/真偽値/
	 * null/シーケンス/マッピング）であれば、コメント・アンカー・タグ・
	 * （数値/文字列以外の）フォーマット情報は保持したまま値のみを書き換える。
	 * 種類が異なる場合は値を新規に構築し直す
	 * （コメント・アンカー・タグは`dst`のものを保持する）。
	 * 
	 * 数値・文字列を更新する際は元の`raw`テキストを必ずクリアする
	 * （更新後の値と元のテキスト表記が乖離するのを防ぐため）。
	 * `dst`が`YamlAlias`（`*name`）だった場合はエイリアスを解除し、`dst`
	 * 自体を更新後の具体値に置き換える（アンカー定義側は変化しない）。
	 * エイリアス参照そのものを維持したい場合は`update()`
	 * ではなく`dst = builder.make(...)`などで明示的に再代入すること。
	 * 
	 * シーケンス/マッピングは要素/キー単位で再帰的に更新される。マッピングは
	 * `src`に存在するキーの集合に同期し、`dst`側にのみ存在するキーは
	 * 削除される。
	 * 
	 * 対応する`src`の型は`YamlValue`・文字列・整数・浮動小数点・真偽値・
	 * `null`・配列・連想配列（キーは`string`）。集約型(struct)・Tuple・
	 * SumTypeへの対応はSerializer/Deserializer実装後に追加する。
	 * Params:
	 *      dst = 更新対象のノード
	 *      src = 更新に使う値
	 */
	void update(T)(ref YamlValue dst, in T src) @safe
	{
		updateValueImpl(dst, src);
	}
	///
	@safe unittest
	{
		YamlBuilder builder;
		// コメント付きの既存ノードをパースしておく
		auto v = builder.parse("count: 1 # 現在の値\n");
		
		// 値だけを更新しても、コメントなどのフォーマット情報は保持される
		builder.update(v.asMapping["count"], 42);
		auto app = appender!(char[])();
		builder.toPrettyString(app, v);
		assert(app.data == "count: 42 # 現在の値\n");
	}
	
	// ==========================================================================
	// MARK: - - Serializer
	// ==========================================================================
	// D型の値をYamlValueへ変換する。フォーマット属性(comment/scalarStyle/
	// integralFormat/floatingPointFormat/arrayFormat/mappingFormat/
	// keyStyle/anchor/tag)を反映しながら、構造体・配列・連想配列・
	// SumType・Tuple等を再帰的にシリアライズする。
	
	/***************************************************************************
	 * D型の値からYamlValueを構築する(シリアライズ)
	 * 
	 * 対応する`T`の種類:
	 * 
	 * - `YamlValue`(`deepCopy()`される)
	 * - 整数型・浮動小数点型・真偽値型・文字列型・`null`
	 * - バイナリ型(`immutable(ubyte)[]`、Base64URL(パディング無し)エンコード
	 *   文字列として出力)
	 * - 配列・連想配列(キーは`string`のみ) - 再帰的にシリアライズ
	 * - `Tuple` - シーケンスに変換し、再帰的にシリアライズ
	 * - `SumType` - 集約型バリアントは`@kind`属性のキー・値をマッピング先頭に
	 *   追加してから判別に用いる。それ以外はそのままシリアライズする
	 * - 集約型(struct/class/union): 以下のいずれかの条件を満たすもの
	 *   - `toYaml`/`fromYaml`メンバーを持つ(`toYaml`はビルダー引数の有無を問わない)
	 *   - 単純な公開メンバー変数で構成される
	 *     - `@ignore`属性: シリアライズ対象から除外する
	 *     - `@ignoreIf`属性: 条件を満たす場合はシリアライズ対象から除外する
	 *     - `@name`属性: キー名としてその値を使う
	 *     - `@value`属性: メンバー値の代わりにその値をシリアライズする
	 *     - `@converter`/`@convBy`属性: 指定した変換関数の戻り値を使う
	 *     - フォーマット属性(`comment`/`scalarStyle`/`integralFormat`/
	 *       `floatingPointFormat`/`arrayFormat`/`mappingFormat`/`keyStyle`/
	 *       `anchor`/`tag`)が付与されていればそれを出力に反映する
	 * Params:
	 *      src = シリアライズ対象の値
	 * Returns:
	 *      構築された`YamlValue`
	 */
	YamlValue serialize(T)(in T src) @safe
	{
		import std.base64: Base64URLNoPadding;
		alias U = Unqual!T;
		static if (is(U == YamlValue))
			return deepCopy(src);
		else static if (isSomeString!T)
			return make(src);
		else static if (isIntegral!T)
			return make(src);
		else static if (isFloatingPoint!T)
			return make(src);
		else static if (isBoolean!T)
			return make(src);
		else static if (isBinary!T)
			return make(Base64URLNoPadding.encode(src));
		else static if (is(T == typeof(null)))
			return make(src);
		else static if (isArray!T)
		{
			auto ary = allocAry!YamlValue();
			foreach (idx; 0..src.length)
				ary ~= serialize(src[idx]);
			return make(YamlSequence(ary));
		}
		else static if (isAssociativeArray!T)
		{
			auto dic = allocDic!(YamlKey, YamlValue)();
			foreach (ref k, ref v; src)
				dic.append(YamlKey(allocStr(k)), serialize(v));
			return make(YamlMapping(dic));
		}
		else static if (isTuple!T)
		{
			auto ary = allocAry!YamlValue();
			static foreach (idx; 0..src[].length)
				ary ~= serialize(src[idx]);
			return make(YamlSequence(ary));
		}
		else static if (isSumType!T)
		{
			// SumTypeの場合
			// 集約型バリアントは`@kind`属性のキー・値をマッピング先頭に追加して
			// 判別に用いる。それ以外は整数・実数・文字列・真偽値・配列・
			// 連想配列のいずれかがユニークでなければならない(isSerializableSumType参照)
			return src.match!(
				(ref e) @safe
				{
					static if (isAggregateType!(typeof(e)) && hasKind!(typeof(e)))
					{
						auto obj = serialize(e);
						enum kd = getKind!(typeof(e));
						obj.asMapping.value.prepend(YamlKey(allocStr(kd.key)), make(kd.value));
						return obj;
					}
					else
					{
						return serialize(e);
					}
				}
			);
		}
		else static if (isAggregateType!T && hasConvertYamlMethodA!T)
			return src.toYaml(this);
		else static if (isAggregateType!T && hasConvertYamlMethodB!T)
			return src.toYaml();
		else static if (isAggregateType!T)
		{
			auto obj = allocDic!(YamlKey, YamlValue)();
			static foreach (i, e; src.tupleof[])
			{
				// メンバー変数をシリアライズする
				// @ignore属性が付与されている場合はシリアライズしない
				// @ignoreIf属性が付与されている場合はその条件に合致する場合はシリアライズしない
				// @name属性が付与されている場合はその名前を使用する
				// @value属性が付与されている場合はその値を使用する
				// @converter属性が付与されている場合はその関数による変換値を使用する
				static if (isAccessible!e && !hasIgnore!e)
				{{
					alias E = typeof(e);
					alias appendObj = ()
					{
						static if (hasName!e)
							alias getname = () => YamlKey(allocStr(getName!e));
						else
							alias getname = () => YamlKey(allocStr(e.stringof));
						static if (hasConvBy!e && canConvTo!(e, string))
							alias getval = () => make(convTo!(e, string)(src.tupleof[i]));
						else static if (hasConvBy!e && canConvTo!(e, immutable(ubyte)[]))
							alias getval = () => serialize(convTo!(e, immutable(ubyte)[])(src.tupleof[i]));
						else static if (hasConvBy!e && canConvTo!(e, YamlValue))
						{
							alias getval = () {
								auto v = undefinedValue();
								convertTo!e(src.tupleof[i], v);
								return v;
							};
						}
						else static if (hasValue!e)
							alias getval = () => serialize(getValue!e);
						else
							alias getval = () => serialize(src.tupleof[i]);
						auto key = getname();
						auto val = getval();
						// コメント
						static foreach (c; getAttrYamlComments!e)
							val.addComment(c.value, c.type);
						// キー出力スタイル
						static if (hasAttrYamlKeyStyle!e)
							key.style = getAttrYamlKeyStyle!e.style;
						else static if (hasAttrYamlKeyStyle!T)
							key.style = getAttrYamlKeyStyle!T.style;
						// 各型の修飾
						static if (isSomeString!E && hasAttrYamlScalarStyle!e)
						{
							assert(val.type == YamlType.string);
							val.asString.style = getAttrYamlScalarStyle!e.style;
						}
						else static if (isIntegral!E && isSigned!E && hasAttrYamlIntegralFormat!e)
						{
							assert(val.type == YamlType.integer);
							val.asInteger.positiveSign = getAttrYamlIntegralFormat!e.positiveSign;
							val.asInteger.base         = getAttrYamlIntegralFormat!e.base;
						}
						else static if (isIntegral!E && isUnsigned!E && hasAttrYamlIntegralFormat!e)
						{
							assert(val.type == YamlType.uinteger);
							val.asUInteger.positiveSign = getAttrYamlIntegralFormat!e.positiveSign;
							val.asUInteger.base         = getAttrYamlIntegralFormat!e.base;
						}
						else static if (isFloatingPoint!E && hasAttrYamlFloatingPointFormat!e)
						{
							assert(val.type == YamlType.floating);
							val.asFloatingPoint.leadingDecimalPoint = getAttrYamlFloatingPointFormat!e.leadingDecimalPoint;
							val.asFloatingPoint.tailingDecimalPoint = getAttrYamlFloatingPointFormat!e.tailingDecimalPoint;
							val.asFloatingPoint.positiveSign        = getAttrYamlFloatingPointFormat!e.positiveSign;
							val.asFloatingPoint.withExponent        = getAttrYamlFloatingPointFormat!e.withExponent;
							val.asFloatingPoint.precision           = getAttrYamlFloatingPointFormat!e.precision;
						}
						else static if (isArray!E && !isSomeString!E && hasAttrYamlArrayFormat!e)
						{
							assert(val.type == YamlType.sequence);
							val.asSequence.style         = getAttrYamlArrayFormat!e.style;
							val.asSequence.trailingComma = getAttrYamlArrayFormat!e.trailingComma;
							val.asSequence.singleLine    = getAttrYamlArrayFormat!e.singleLine;
						}
						else static if (isAggregateType!E && hasAttrYamlMappingFormat!e)
						{
							assert(val.type == YamlType.mapping);
							val.asMapping.style         = getAttrYamlMappingFormat!e.style;
							val.asMapping.trailingComma = getAttrYamlMappingFormat!e.trailingComma;
							val.asMapping.singleLine    = getAttrYamlMappingFormat!e.singleLine;
						}
						else
						{
							// 何もしない
						}
						// アンカー・タグ
						static if (hasAttrYamlAnchor!e)
							val.setAnchor(getAttrYamlAnchor!e.anchorName);
						static if (hasAttrYamlTag!e)
							val.setTag(getAttrYamlTag!e.tagName);
						// 配列の要素に対する修飾(多重配列は非対応)
						static if (isArray!E && isSomeString!(ElementType!E) && hasAttrYamlScalarStyle!e)
						{
							foreach (ref elm; val.asSequence.value[])
							{
								assert(elm.type == YamlType.string);
								elm.asString.style = getAttrYamlScalarStyle!e.style;
							}
						}
						else static if (isArray!E && isIntegral!(ElementType!E) && isSigned!(ElementType!E)
							&& hasAttrYamlIntegralFormat!e)
						{
							foreach (ref elm; val.asSequence.value[])
							{
								assert(elm.type == YamlType.integer);
								elm.asInteger.positiveSign = getAttrYamlIntegralFormat!e.positiveSign;
								elm.asInteger.base         = getAttrYamlIntegralFormat!e.base;
							}
						}
						else static if (isArray!E && isIntegral!(ElementType!E) && isUnsigned!(ElementType!E)
							&& hasAttrYamlIntegralFormat!e)
						{
							foreach (ref elm; val.asSequence.value[])
							{
								assert(elm.type == YamlType.uinteger);
								elm.asUInteger.positiveSign = getAttrYamlIntegralFormat!e.positiveSign;
								elm.asUInteger.base         = getAttrYamlIntegralFormat!e.base;
							}
						}
						else static if (isArray!E && isFloatingPoint!(ElementType!E)
							&& hasAttrYamlFloatingPointFormat!e)
						{
							enum fpFormat = getAttrYamlFloatingPointFormat!e;
							foreach (ref elm; val.asSequence.value[])
							{
								assert(elm.type == YamlType.floating);
								elm.asFloatingPoint.leadingDecimalPoint = fpFormat.leadingDecimalPoint;
								elm.asFloatingPoint.tailingDecimalPoint = fpFormat.tailingDecimalPoint;
								elm.asFloatingPoint.positiveSign        = fpFormat.positiveSign;
								elm.asFloatingPoint.withExponent        = fpFormat.withExponent;
								elm.asFloatingPoint.precision           = fpFormat.precision;
							}
						}
						else static if (isArray!E && isAggregateType!(ElementType!E) && hasAttrYamlMappingFormat!e)
						{
							foreach (ref elm; val.asSequence.value[])
							{
								assert(elm.type == YamlType.mapping);
								elm.asMapping.style         = getAttrYamlMappingFormat!e.style;
								elm.asMapping.trailingComma = getAttrYamlMappingFormat!e.trailingComma;
								elm.asMapping.singleLine    = getAttrYamlMappingFormat!e.singleLine;
							}
						}
						else
						{
							// 何もしない
						}
						obj.append(key, val);
					};
					static if (hasIgnoreIf!(e, const(E)))
					{
						if (!getPredIgnoreIf!e(src.tupleof[i]))
							appendObj();
					}
					else static if (hasIgnoreIf!(e, T))
					{
						if (!getPredIgnoreIf!e(src))
							appendObj();
					}
					else static if (isPointer!(typeof(e)) && e.stringof == "this")
					{
						// クロージャの隠しコンテキストポインタ対策
						// (ネストした構造体の`this`メンバーをスキップするワークアラウンド)
						if (false)
							appendObj();
					}
					else
					{
						appendObj();
					}
				}}
			}
			static if (hasAttrYamlMappingFormat!T)
			{
				enum mfmt = getAttrYamlMappingFormat!T;
				return make(YamlMapping(obj, mfmt.style, mfmt.trailingComma, mfmt.singleLine));
			}
			else
			{
				return make(YamlMapping(obj));
			}
		}
		else
		{
			return undefinedValue();
		}
	}
	///
	@safe unittest
	{
		static struct Person
		{
			string name;
			int age;
		}
		YamlBuilder builder;
		auto v = builder.serialize(Person("Alice", 20));
		auto app = appender!(char[])();
		builder.toPrettyString(app, v);
		assert(app.data == "name: Alice\nage: 20\n");
	}
	
	// ==========================================================================
	// MARK: - - Deserializer
	// ==========================================================================
	// YamlValueからD型の値を復元する。Tuple分岐を含む全ての分岐で
	// `deserializeImpl()`を直接呼び出す(例外を握り潰す公開ラッパー
	// `deserialize()`は経由しない)。SumType分岐は`switch`ではなく
	// `final switch`を使用し、`YamlType.alias_`(`dereference()`済みのため
	// 実行時には到達しない)を`assert(0)`で明示することで、将来`Type`に
	// バリアントが追加された際にコンパイルエラーで気づけるようにしている。
	
	/***************************************************************************
	 * YamlValueから指定した型の値へデシリアライズする
	 * 
	 * 対応する`T`の種類は`serialize()`とほぼ対称:
	 * 
	 * - `YamlValue`(`deepCopy()`される)
	 * - 整数型・浮動小数点型・真偽値型・文字列型・`null`
	 * - バイナリ型(`immutable(ubyte)[]`、Base64URLデコード)
	 * - 配列・連想配列 - 再帰的にデシリアライズ
	 * - `Tuple` - シーケンスから復元
	 * - `SumType` - マッピング先頭の`@kind`タグ、または整数/実数/文字列/
	 *   真偽値/null/配列/連想配列の型から一意に判定して復元
	 * - 集約型(struct/class/union): 以下のいずれかの条件を満たすもの
	 *   - `toYaml`/`fromYaml`メンバーを持つ
	 *   - 単純な公開メンバー変数で構成される
	 *     - `@ignore`属性: デシリアライズしない
	 *     - `@ignoreIf`属性: 条件を満たす場合はデシリアライズしない
	 *     - `@name`属性: キー名としてその値を使う
	 *     - `@converter`/`@convBy`属性: 指定した変換関数を使う
	 *     - `@essential`属性: 対応するキーが見つからない場合は例外を投げる
	 * Params:
	 *      src = デシリアライズ元の値
	 *      dst = デシリアライズ先(出力引数)
	 */
	void deserializeImpl(T)(in YamlValue src, ref T dst) @safe
	{
		import std.base64: Base64URLNoPadding;
		alias U = Unqual!T;
		static if (is(U == YamlValue))
			dst = deepCopy(src);
		else static if (isSomeString!T)
			dst = src.get!U;
		else static if (isIntegral!T)
			dst = src.get!U;
		else static if (isFloatingPoint!T)
			dst = src.get!U;
		else static if (isBoolean!T)
			dst = src.get!U;
		else static if (isBinary!T)
			dst = Base64URLNoPadding.decode(src.get!string);
		else static if (is(T == typeof(null)))
			dst = null;
		else static if (isArray!T)
		{
			// 配列
			dst.length = src.dereference()._reqSeq.length;
			foreach (i, ref e; src.dereference()._reqSeq)
				deserializeImpl(e, dst[i]);
		}
		else static if (isAssociativeArray!T)
		{
			// 連想配列
			foreach (ref e; src.dereference()._reqMap.byKeyValue)
			{
				ValueType!T val;
				deserializeImpl(e.value, val);
				dst[cast(string)e.key.value[]] = val;
			}
		}
		else static if (isTuple!T)
		{
			auto ary = src.dereference()._reqSeq;
			static foreach (idx; 0..dst.length)
				deserializeImpl(ary[idx], dst[idx]);
		}
		else static if (isSumType!T)
		{
			// SumTypeの場合
			// 集約型バリアントはマッピング先頭の@kind属性のキー・値を手掛かりに
			// 判別する。それ以外は整数/実数/文字列/真偽値/null/配列/連想配列の
			// いずれかがユニークでなければならない(isSerializableSumType参照)
			final switch (src.dereference().type)
			{
			case YamlType.integer:
			case YamlType.uinteger:
				alias Types = Filter!(isIntegral, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case YamlType.floating:
				alias Types = Filter!(isFloatingPoint, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case YamlType.string:
				alias Types1 = Filter!(isSomeString, T.Types);
				alias Types2 = Filter!(isBinary, T.Types);
				static if (Types1.length == 1 && Types2.length == 0)
				{
					Types1[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				else static if (Types1.length == 0 && Types2.length == 1)
				{
					Types2[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				else
				{
					// Ignore
				}
				break;
			case YamlType.nullfied:
				import std.typecons: NullableRef;
				enum isNullableType(X) = is(X == typeof(null))
					|| isInstanceOf!(Nullable, X) || isInstanceOf!(NullableRef, X);
				alias Types = Filter!(isNullableType, T.Types);
				static if (Types.length == 1)
				{
					static if (is(Types[0] == typeof(null)))
						dst = null;
					else
						dst.nullify();
				}
				break;
			case YamlType.undefined:
				// Ignore
				break;
			case YamlType.boolean:
				alias Types = Filter!(isBoolean, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case YamlType.sequence:
				alias Types = Filter!(isArrayWithoutBinary, T.Types);
				static if (Types.length == 1)
				{
					Types[0] ret;
					deserializeImpl(src, ret);
					(() @trusted => dst = ret.move)();
				}
				break;
			case YamlType.mapping:
				immutable kinds = [staticMap!(getKind, Filter!(isAggregateType, T.Types))];
				size_t kindIdx = size_t.max;
				static if (kinds.length)
				{
					// kindIdxは「マッピング内でのキー出現位置」ではなく「kinds(=Types)
					// 配列内でのマッチ位置」を記録する。@kindタグは常にマッピング先頭に
					// 付与される(serialize()参照)ため、前者を使うと2番目以降のバリアントを
					// 正しく判別できない。
					foreach (ref e; src.dereference()._reqMap.byKeyValue)
					{
						foreach (ki, kd; kinds)
						{
							if (e.key.value[] == kd.key
								&& e.value.dereference().type == YamlType.string
								&& e.value.dereference()._reqStr[] == kd.value)
							{
								kindIdx = ki;
								break;
							}
						}
						if (kindIdx != size_t.max)
							break;
					}
				}
				if (kindIdx != size_t.max)
				{
					// isAggregateType
					alias Types = Filter!(isAggregateType, T.Types);
					static foreach (i, E; Types)
					{
						if (kindIdx == i)
						{
							E ret;
							deserializeImpl(src, ret);
							(() @trusted => dst = ret.move)();
						}
					}
				}
				else
				{
					// isAssociativeArray
					alias Types = Filter!(isAssociativeArray, T.Types);
					static if (Types.length == 1)
					{
						Types[0] ret;
						deserializeImpl(src, ret);
						(() @trusted => dst = ret.move)();
					}
				}
				break;
			case YamlType.alias_:
				assert(0, "unreachable: dereference() must resolve YamlAlias");
			}
		}
		else static if (isAggregateType!T && hasConvertYamlMethodA!T)
			dst = T.fromYaml(src);
		else static if (isAggregateType!T && hasConvertYamlMethodB!T)
			dst = T.fromYaml(src);
		else static if (isAggregateType!T)
		{
			// その他の構造体・クラス
			static foreach (i, m; dst.tupleof[])
			{{
				// メンバー変数をデシリアライズ
				// @ignore属性が付与されている場合はデシリアライズしない
				// @ignoreIf属性が付与されている場合はその条件に合致する場合はデシリアライズしない
				// @name属性が付与されている場合はその名前を使用する
				// @converter属性が付与されている場合はその関数による変換値を使用する
				// @essential属性が付与されている場合は変換できない場合に例外を投げる
				static if (hasEssential!m)
					bool found = false;
				static if (isAccessible!m && !hasIgnore!m)
				{
					static if (hasIgnoreIf!(m, const(YamlValue)))
						bool isIgnored = getPredIgnoreIf!m(src);
					else static if (hasIgnoreIf!(m, typeof(m), const(YamlValue)))
						bool isIgnored = getPredIgnoreIf!(m, typeof(m), const(YamlValue))(dst.tupleof[i], src);
					else static if (hasIgnoreIf!(m, const(T), const(YamlValue)))
						bool isIgnored = getPredIgnoreIf!(m, const(T), const(YamlValue))(dst, src);
					else
						enum isIgnored = false;
					if (!isIgnored) foreach (ref e; src.dereference()._reqMap.byKeyValue)
					{
						static if (hasName!m)
							enum memberName = getName!m;
						else
							enum memberName = m.stringof;
						
						if (e.key.value[] == memberName)
						{
							static if (hasConvBy!m && canConvFrom!(m, string))
								dst.tupleof[i] = convFrom!(m, string)(e.value.get!string);
							else static if (hasConvBy!m && canConvFrom!(m, immutable(ubyte)[]))
							{
								immutable(ubyte)[] tmp;
								deserializeImpl(e.value, tmp);
								dst.tupleof[i] = convFrom!(m, immutable(ubyte)[])(tmp);
							}
							else static if (hasConvBy!m && canConvFrom!(m, YamlValue))
								dst.tupleof[i] = convFrom!(m, YamlValue)(e.value);
							else
								deserializeImpl(e.value, dst.tupleof[i]);
							static if (hasEssential!m)
								found = true;
							break;
						}
					}
				}
				static if (hasEssential!m)
					enforce(found, "Essential member[" ~ m.stringof ~ "] is not found.");
			}}
		}
		else
		{
			// ignore
		}
	}
	/// ditto
	bool deserialize(T)(in YamlValue src, ref T dst) @safe
	{
		return !deserializeImpl(src, dst).collectException;
	}
	/// ditto
	T deserialize(T)(in YamlValue src) @safe
	{
		T dst;
		deserializeImpl(src, dst);
		return dst;
	}
	///
	@safe unittest
	{
		static struct Person
		{
			string name;
			@essential int age;
		}
		YamlBuilder builder;
		auto v = builder.parse("name: Alice\nage: 20\n");
		
		// T deserialize(T)(src): 復元した値をそのまま返す
		auto p = builder.deserialize!Person(v);
		assert(p == Person("Alice", 20));
		
		// bool deserialize(T)(src, ref dst): 失敗時は例外を投げず false を返す
		// (ここでは @essential な age フィールドに対応するキーが存在しないため失敗する)
		Person p2;
		bool ok = builder.deserialize(builder.parse("name: Bob\n"), p2);
		assert(!ok);
	}
}

// ============================================================================
// MARK: - Export Types
// ============================================================================

// エイリアス群。`YamlMapping`/`YamlSequence`が正式名称であり、
// `YamlObject`/`YamlArray`はより簡潔な別名として追加提供する。

///
alias YamlBuilder       = YamlBuilderImpl!YamlDefaultAllocator;
///
alias YamlValue         = YamlBuilder.YamlValue;
///
alias YamlType          = YamlBuilder.YamlType;
///
alias YamlString        = YamlBuilder.YamlValue.YamlString;
///
alias YamlInteger       = YamlBuilder.YamlValue.YamlInteger;
///
alias YamlUInteger      = YamlBuilder.YamlValue.YamlUInteger;
///
alias YamlFloatingPoint = YamlBuilder.YamlValue.YamlFloatingPoint;
///
alias YamlBoolean       = YamlBuilder.YamlValue.YamlBoolean;
///
alias YamlMapping       = YamlBuilder.YamlValue.YamlMapping;
///
alias YamlSequence      = YamlBuilder.YamlValue.YamlSequence;
/// `YamlMapping`の別名エイリアス
alias YamlObject        = YamlMapping;
/// `YamlSequence`の別名エイリアス
alias YamlArray         = YamlSequence;
///
alias YamlOptions       = YamlBuilder.YamlPrettyPrintOptions;

// `YamlBuilder`はパース時にアンカーテーブル(`_anchorTable`)や保留コメント
// (`_pendingComments`)を実インスタンスフィールドとして保持するステート
// フルな構造体である(`hasIndirections!YamlBuilder == true`)。そのため
// 以下の自由関数群では`__gshared`のBuilderを共有せず、呼び出しごとに
// ローカルな`YamlBuilder`インスタンスを生成する設計にしている
// (共有した場合、`@safe`関数から`__gshared`データへアクセスできない
// 上、複数スレッド・再入呼び出し間でパース状態を共有してしまう問題が
// ある。既定アロケータでは`YamlBuilder`の生成は軽量なゼロ初期化のみ
// のため、毎回生成してもコストは小さい)。

/***************************************************************************
 * 値からYamlValueを構築する(既定のBuilderを使用する自由関数版)
 */
YamlValue makeYaml(T)(in T val) @safe
{
	YamlBuilder builder;
	return builder.make(val);
}

/***************************************************************************
 * YAML文字列をパースする(既定のBuilderを使用する自由関数版)
 */
YamlValue parseYaml(in char[] str) @safe
{
	YamlBuilder builder;
	return builder.parse(str);
}

/***************************************************************************
 * D型の値をYamlValueへシリアライズする(既定のBuilderを使用する自由関数版)
 */
YamlValue serializeToYaml(T)(in T src) @safe
{
	YamlBuilder builder;
	return builder.serialize(src);
}

/***************************************************************************
 * D型の値をYAML文字列へシリアライズする(既定のBuilderを使用する自由関数版)
 * Params:
 *      src     = シリアライズ対象の値
 *      options = pretty-print整形オプション(既定値: `YamlOptions.init`)
 */
string serializeToYamlString(T)(in T src, YamlOptions options = YamlOptions.init) @safe
{
	YamlBuilder builder;
	auto app = appender!string;
	auto v = builder.serialize(src);
	builder.toPrettyString(app, v, options);
	return app.data;
}

/***************************************************************************
 * YamlValueからD型の値へデシリアライズする(既定のBuilderを使用する自由関数版)
 */
bool deserializeFromYaml(T)(in YamlValue src, ref T dst) @safe
{
	YamlBuilder builder;
	return builder.deserialize(src, dst);
}
/// ditto
T deserializeFromYaml(T)(in YamlValue src) @safe
{
	YamlBuilder builder;
	return builder.deserialize!T(src);
}

/***************************************************************************
 * YAML文字列をパースしてD型の値へデシリアライズする
 * (既定のBuilderを使用する自由関数版)
 */
bool deserializeFromYamlString(T)(in char[] src, ref T dst) @safe
{
	YamlBuilder builder;
	return builder.deserialize(builder.parse(src), dst);
}
/// ditto
T deserializeFromYamlString(T)(in char[] src) @safe
{
	YamlBuilder builder;
	return builder.deserialize!T(builder.parse(src));
}

/// 自由関数API(`makeYaml`/`parseYaml`/`serializeToYaml`/`serializeToYamlString`/
/// `deserializeFromYaml`/`deserializeFromYamlString`)の組み合わせ例
@safe unittest
{
	struct Data
	{
		int x;
		int y;
	}
	auto dat1 = Data(1, 2);
	auto str1 = dat1.serializeToYamlString();
	assert(str1 == "x: 1\ny: 2\n");
	
	auto v1 = parseYaml(str1);
	assert(v1.getValue!int("x") == 1);
	assert(v1.getValue!int("y") == 2);
	
	auto dat2 = deserializeFromYamlString!Data("x: 1\ny: 2\n");
	assert(dat1 == dat2);
	
	auto v2 = dat1.serializeToYaml();
	assert(v2.getValue!int("x") == 1);
	assert(v2.getValue!int("y") == 2);
	
	auto dat3 = deserializeFromYaml!Data(makeYaml(["x": 1, "y": 2]));
	assert(dat3 == dat1);
}

// ============================================================================
// MARK: - Unittests
// ============================================================================

// 注: 以下は YamlValue の公開コンストラクタ (YamlValue(val, builder)) を
// 直接使った低レベルのホワイトボックステストである。このコンストラクタは
// @system のため、以下のテストは @system unittest とする。make() 経由の
// @safe なテストは Builder Factory セクションおよび後述の別テストを参照。

// 基本的なスカラー値の構築とget()
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(cast(string)"hello", builder);
	assert(v.type == YamlBuilder.YamlType.string);
	assert(v.get!string == "hello");
	
	auto vi = YamlValue(cast(int)42, builder);
	assert(vi.type == YamlBuilder.YamlType.integer);
	assert(vi.get!int == 42);
	
	auto vu = YamlValue(cast(uint)42, builder);
	assert(vu.type == YamlBuilder.YamlType.uinteger);
	assert(vu.get!uint == 42);
	
	auto vf = YamlValue(cast(double)3.14, builder);
	assert(vf.type == YamlBuilder.YamlType.floating);
	
	auto vb = YamlValue(true, builder);
	assert(vb.type == YamlBuilder.YamlType.boolean);
	assert(vb.get!bool == true);
	
	auto vn = YamlValue(null, builder);
	assert(vn.type == YamlBuilder.YamlType.nullfied);
}

// 配列・連想配列の構築
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue([1, 2, 3], builder);
	assert(v.type == YamlBuilder.YamlType.sequence);
	assert(v.get!(int[]) == [1, 2, 3]);
	
	auto vm = YamlValue(["a": 1, "b": 2], builder);
	assert(vm.type == YamlBuilder.YamlType.mapping);
	assert(vm.getValue!int("a") == 1);
	assert(vm.getValue!int("b") == 2);
}

// コメント操作
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(cast(string)"x", builder);
	v.addLineComment("this is a line comment");
	v.addTrailingComment("trailing");
	assert(v.getCommentLength == 2);
	assert(v.isLineComment(0));
	assert(v.isTrailingComment(1));
	assert(v.hasTrailingComment);
	assert(v.getComment(0) == "this is a line comment");
}

// アンカー・タグの設定
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(cast(string)"x", builder);
	assert(v.anchorName.isNull);
	v.setAnchor("myanchor");
	assert(!v.anchorName.isNull);
	assert(v.anchorName.get == "myanchor");
	v.clearAnchor();
	assert(v.anchorName.isNull);
	
	v.setTag("mytag");
	assert(v.tagName.get == "mytag");
}

// エイリアスのdereference透過アクセス
@system unittest
{
	YamlBuilder builder;
	auto resolved = new YamlValue(cast(int)100, builder);
	YamlBuilder.YamlAlias aliasVal;
	aliasVal.resolved = resolved;
	auto v = YamlValue(aliasVal, builder);
	assert(v.type == YamlBuilder.YamlType.alias_);
	// dereferenceを経由してint値として取得できる
	assert(v.get!int == 100);
	assert(v.dereference.type == YamlBuilder.YamlType.integer);
}

// skipBOMImpl
@safe unittest
{
	YamlBuilder builder;
	assert(builder.skipBOMImpl("\uFEFFabc") == 3);
	assert(builder.skipBOMImpl("abc") == 0);
	assert(builder.skipBOMImpl("") == 0);
}

// skipNewlineImpl - 改行なし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 5;
	assert(builder.skipNewlineImpl("abc", line, col) == 0);
	assert(line == 1 && col == 5);
	assert(builder.skipNewlineImpl("", line, col) == 0);
}

// skipNewlineImpl - 改行コード3種(\n / \r\n / \r)の正規化
@safe unittest
{
	YamlBuilder builder;
	// LF
	{
		size_t line = 1, col = 5;
		assert(builder.skipNewlineImpl("\nabc", line, col) == 1);
		assert(line == 2 && col == 1);
	}
	// CRLF
	{
		size_t line = 1, col = 5;
		assert(builder.skipNewlineImpl("\r\nabc", line, col) == 2);
		assert(line == 2 && col == 1);
	}
	// CR単体
	{
		size_t line = 1, col = 5;
		assert(builder.skipNewlineImpl("\rabc", line, col) == 1);
		assert(line == 2 && col == 1);
	}
}

// measureIndentImpl - 複数インデント量パターン
@safe unittest
{
	YamlBuilder builder;
	foreach (depth; [0, 1, 2, 4, 8])
	{
		size_t col = 1;
		auto src = " ".repeat(depth).join() ~ "key: value";
		auto consumed = builder.measureIndentImpl(src, 1, col);
		assert(consumed == depth);
		assert(col == depth + 1);
	}
}

// measureIndentImpl - 改行/文字列末尾で計測終了
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	assert(builder.measureIndentImpl("  \nnext", 1, col) == 2);
	col = 1;
	assert(builder.measureIndentImpl("   ", 1, col) == 3);
}

// measureIndentImpl - タブ混入で例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t col = 1;
	assertThrown!YamlParseException(builder.measureIndentImpl("  \tkey: value", 1, col));
	// タブが先頭に来る場合も同様
	col = 1;
	assertThrown!YamlParseException(builder.measureIndentImpl("\tkey: value", 1, col));
}

// 改行コード3種 x インデント量複数パターンの直交組み合わせで行列カウンタを検証
@safe unittest
{
	YamlBuilder builder;
	foreach (nl; ["\n", "\r\n", "\r"])
	{
		foreach (depth; [0, 2, 4])
		{
			size_t line = 1, col = 1;
			auto rest = nl ~ " ".repeat(depth).join() ~ "key: value";
			auto nlLen = builder.skipNewlineImpl(rest, line, col);
			assert(nlLen == nl.length);
			assert(line == 2 && col == 1);
			auto indentLen = builder.measureIndentImpl(rest[nlLen .. $], line, col);
			assert(indentLen == depth);
			assert(col == depth + 1);
		}
	}
}

// isPlainScalarTerminator - EOF
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator("", false) == true);
}

// isPlainScalarTerminator - `key: value` のコロン+空白による終端
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator(": value", false) == true);
	assert(builder.isPlainScalarTerminator(":\tvalue", false) == true);
	assert(builder.isPlainScalarTerminator(":\nvalue", false) == true);
	assert(builder.isPlainScalarTerminator(":", false) == true);
}

// isPlainScalarTerminator - `key:value` はコロン後ろが空白でないため終端しない
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator(":value", false) == false);
	assert(builder.isPlainScalarTerminator(":1", false) == false);
}

// isPlainScalarTerminator - フロー文脈での `,`/`]`/`}` による終端
@safe unittest
{
	YamlBuilder builder;
	// フロー文脈では終端になる
	assert(builder.isPlainScalarTerminator(",next", true) == true);
	assert(builder.isPlainScalarTerminator("]next", true) == true);
	assert(builder.isPlainScalarTerminator("}next", true) == true);
	assert(builder.isPlainScalarTerminator(":,", true) == true);
	assert(builder.isPlainScalarTerminator(":]", true) == true);
	assert(builder.isPlainScalarTerminator(":}", true) == true);
	// ブロック文脈では終端にならない(通常の文字として扱う)
	assert(builder.isPlainScalarTerminator(",next", false) == false);
	assert(builder.isPlainScalarTerminator("]next", false) == false);
	assert(builder.isPlainScalarTerminator("}next", false) == false);
}

// isPlainScalarTerminator - 末尾の空白+コメント/改行/EOF
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator(" #comment", false) == true);
	assert(builder.isPlainScalarTerminator("   #comment", false) == true);
	assert(builder.isPlainScalarTerminator(" \n", false) == true);
	assert(builder.isPlainScalarTerminator("  ", false) == true);
	// 空白の後に通常文字が続く場合は終端ではない
	assert(builder.isPlainScalarTerminator(" abc", false) == false);
}

// parsePlainScalarImpl - `key: value` のコロン+空白による終端
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "key: value", line, col, 0, false);
	assert(consumed == 3);
	assert(dst.value[] == "key");
}

// parsePlainScalarImpl - `key:value` はコロンの後ろが空白でないため終端しない
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "key:value", line, col, 0, false);
	assert(consumed == 9);
	assert(dst.value[] == "key:value");
}

// parsePlainScalarImpl - フロー文脈内の`,`/`]`/`}`による終端
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto consumed = builder.parsePlainScalarImpl(dst, "abc,def", line, col, 0, true);
		assert(consumed == 3);
		assert(dst.value[] == "abc");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto consumed = builder.parsePlainScalarImpl(dst, "abc]def", line, col, 0, true);
		assert(consumed == 3);
		assert(dst.value[] == "abc");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto consumed = builder.parsePlainScalarImpl(dst, "abc}def", line, col, 0, true);
		assert(consumed == 3);
		assert(dst.value[] == "abc");
	}
	// ブロック文脈では終端にならず全体が1つのスカラーになる
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto consumed = builder.parsePlainScalarImpl(dst, "abc,def", line, col, 0, false);
		assert(consumed == 7);
		assert(dst.value[] == "abc,def");
	}
}

// parsePlainScalarImpl - 複数行の折り畳み(改行は1スペースに変換)
@safe unittest
{
	YamlBuilder builder;
	// 単純な折り返し
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "abc\n  def";
		auto consumed = builder.parsePlainScalarImpl(dst, src, line, col, 2, false);
		assert(consumed == src.length);
		assert(dst.value[] == "abc def");
	}
	// 空行を挟んでも1スペースに折り畳む(簡易方針)
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "abc\n\n  def";
		auto consumed = builder.parsePlainScalarImpl(dst, src, line, col, 2, false);
		assert(consumed == src.length);
		assert(dst.value[] == "abc def");
	}
	// 3行以上の継続
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "abc\n  def\n  ghi";
		auto consumed = builder.parsePlainScalarImpl(dst, src, line, col, 2, false);
		assert(consumed == src.length);
		assert(dst.value[] == "abc def ghi");
	}
}

// parsePlainScalarImpl - 継続行のインデント不足で終端(改行は消費しない)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "abc\ndef";
	// minIndent=2 だが継続行 "def" のインデントは0なので継続とみなさない
	auto consumed = builder.parsePlainScalarImpl(dst, src, line, col, 2, false);
	assert(consumed == 3);
	assert(dst.value[] == "abc");
	assert(line == 1);
}

// parsePlainScalarImpl - 行末の余分な空白はトリムされる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "abc   \ndef";
	auto consumed = builder.parsePlainScalarImpl(dst, src, line, col, 0, false);
	assert(consumed == src.length);
	assert(dst.value[] == "abc def");
}

// parsePlainScalarImpl - 行末コメントの手前で終端する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "abc # comment", line, col, 0, false);
	assert(consumed == 3);
	assert(dst.value[] == "abc");
}

// parseSingleQuotedImpl - 基本のシングルクォート文字列
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseSingleQuotedImpl(dst, "'hello'rest", line, col, 0);
	assert(consumed == 7);
	assert(dst.value[] == "hello");
	assert(dst.style == ScalarStyle.singleQuoted);
	assert(col == 8);
}

// parseSingleQuotedImpl - `''`エスケープ(1つのシングルクォートリテラル)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseSingleQuotedImpl(dst, "'it''s'rest", line, col, 0);
	assert(consumed == 7);
	assert(dst.value[] == "it's");
}

// parseSingleQuotedImpl - バックスラッシュは特別扱いされない(リテラルのまま)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseSingleQuotedImpl(dst, `'a\nb'`, line, col, 0);
	assert(dst.value[] == `a\nb`);
}

// parseSingleQuotedImpl - 複数行の折り畳み
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "'abc\n  def'";
	auto consumed = builder.parseSingleQuotedImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "abc def");
}

// parseSingleQuotedImpl - 閉じクォートなしで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseSingleQuotedImpl(dst, "'unterminated", line, col, 0));
}

// parseDoubleQuotedImpl - 基本のダブルクォート文字列
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseDoubleQuotedImpl(dst, `"hello"rest`, line, col, 0);
	assert(consumed == 7);
	assert(dst.value[] == "hello");
	assert(dst.style == ScalarStyle.doubleQuoted);
}

// parseDoubleQuotedImpl - 名前付きエスケープシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseDoubleQuotedImpl(dst, `"a\nb\tc\\d\"e"`, line, col, 0);
	assert(dst.value[] == "a\nb\tc\\d\"e");
}

// parseDoubleQuotedImpl - 16進エスケープ(\x, \u, \U)
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		builder.parseDoubleQuotedImpl(dst, `"\x41"`, line, col, 0);
		assert(dst.value[] == "A");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		builder.parseDoubleQuotedImpl(dst, `"\u3042"`, line, col, 0);
		assert(dst.value[] == "あ");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		builder.parseDoubleQuotedImpl(dst, `"\U0001F600"`, line, col, 0);
		assert(dst.value[] == "\U0001F600");
	}
}

// parseDoubleQuotedImpl - 行継続(バックスラッシュ+改行は除去、スペース挿入なし)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "\"abc\\\n  def\"";
	auto consumed = builder.parseDoubleQuotedImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "abcdef");
}

// parseDoubleQuotedImpl - エスケープなし改行は半角スペース1つに折り畳む
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "\"abc\n  def\"";
	auto consumed = builder.parseDoubleQuotedImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "abc def");
}

// parseDoubleQuotedImpl - 不正なエスケープシーケンスで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"\q"`, line, col, 0));
}

// parseDoubleQuotedImpl - 桁数不足の16進エスケープで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"\u12"`, line, col, 0));
}

// parseDoubleQuotedImpl - 閉じクォートなしで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"unterminated`, line, col, 0));
}

// parseBlockScalarImpl - literalスタイル基本(chomping=clip既定)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|\n  line1\n  line2\n";
	auto consumed = builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "line1\nline2\n");
	assert(dst.style == ScalarStyle.literal);
	assert(dst.chomping == ChompingIndicator.clip);
}

// parseBlockScalarImpl - chomping代表例(strip/clip/keep、YAML仕様の例に相当)
@safe unittest
{
	YamlBuilder builder;
	// strip: 末尾の改行をすべて除去
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "|-\n  text\n\n\n";
		builder.parseBlockScalarImpl(dst, src, line, col, 0);
		assert(dst.value[] == "text");
	}
	// clip(既定): 末尾の改行を1つだけ残す
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "|\n  text\n\n\n";
		builder.parseBlockScalarImpl(dst, src, line, col, 0);
		assert(dst.value[] == "text\n");
	}
	// keep: 末尾の改行をすべて残す
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "|+\n  text\n\n\n";
		builder.parseBlockScalarImpl(dst, src, line, col, 0);
		assert(dst.value[] == "text\n\n\n");
	}
}

// parseBlockScalarImpl - foldedスタイル: 単一改行はスペースに変換
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = ">\n  folded\n  line\n\n  next\n  line\n";
	builder.parseBlockScalarImpl(dst, src, line, col, 0);
	// YAML仕様の代表例: 単一改行はスペース、空行はそのまま改行として残る
	assert(dst.value[] == "folded line\nnext line\n");
	assert(dst.style == ScalarStyle.folded);
}

// parseBlockScalarImpl - foldedスタイル: 空行は改行として保持(複数空行)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = ">\n  abc\n\n\n  def\n";
	builder.parseBlockScalarImpl(dst, src, line, col, 0);
	// 空行2つ -> 改行2つ(単一改行のスペース変換とは区別される)
	assert(dst.value[] == "abc\n\ndef\n");
}

// parseBlockScalarImpl - 明示インデント指定子
@safe unittest
{
	YamlBuilder builder;
	// "|2" は minIndent=0 からの相対で2桁インデントを基準にする
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|2\n    abc\n  def\n";
	// baseIndent=2: "    abc"は2つ分の余剰インデントを保持したまま内容になり、
	// "  def"はbaseIndent=2ちょうどなのでそのまま内容になる
	auto consumed = builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "  abc\ndef\n");
	assert(!dst.explicitIndent.isNull);
	assert(dst.explicitIndent.get == 2);
}

// parseBlockScalarImpl - 明示インデント+chomping指定子(順序を問わない)
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "|2-\n    abc\n";
		builder.parseBlockScalarImpl(dst, src, line, col, 0);
		assert(dst.value[] == "  abc");
		assert(dst.chomping == ChompingIndicator.strip);
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlString dst;
		auto src = "|-2\n    abc\n";
		builder.parseBlockScalarImpl(dst, src, line, col, 0);
		assert(dst.value[] == "  abc");
		assert(dst.chomping == ChompingIndicator.strip);
	}
}

// parseBlockScalarImpl - インデント自動検出(最初の非空行から決定)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|\n    abc\n    def\n";
	builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(dst.value[] == "abc\ndef\n");
}

// parseBlockScalarImpl - 親のインデント以下に戻ったら終了(後続を消費しない)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|\n  abc\n  def\nnext: value\n";
	auto consumed = builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(dst.value[] == "abc\ndef\n");
	// "next: value" 行は消費されず残っている
	assert(src[consumed .. $] == "next: value\n");
}

// parseBlockScalarImpl - 空のブロックスカラー
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|\nnext: value\n";
	auto consumed = builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(dst.value[] == "");
	assert(src[consumed .. $] == "next: value\n");
}

// parseBlockScalarImpl - ヘッダ行のコメント
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "| # a comment\n  abc\n";
	auto consumed = builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.value[] == "abc\n");
}

// resolveScalarTypeImpl - 型分類のテーブル駆動テスト
// (Core Schema仕様と1.1互換ケースを1つの配列にまとめて反復実行)
@safe unittest
{
	YamlBuilder builder;
	static struct Case { string raw; YamlBuilder.YamlType expected; }
	static immutable Case[] cases = [
		// 暗黙のnull(空文字列、Y11)
		Case("", YamlBuilder.YamlType.nullfied),
		// null候補(1.2 Core Schema)
		Case("~", YamlBuilder.YamlType.nullfied),
		Case("null", YamlBuilder.YamlType.nullfied),
		Case("Null", YamlBuilder.YamlType.nullfied),
		Case("NULL", YamlBuilder.YamlType.nullfied),
		// bool候補(1.2 Core Schema)
		Case("true", YamlBuilder.YamlType.boolean),
		Case("True", YamlBuilder.YamlType.boolean),
		Case("TRUE", YamlBuilder.YamlType.boolean),
		Case("false", YamlBuilder.YamlType.boolean),
		Case("False", YamlBuilder.YamlType.boolean),
		Case("FALSE", YamlBuilder.YamlType.boolean),
		// bool候補(1.1互換: yes/no/on/off)
		Case("yes", YamlBuilder.YamlType.boolean),
		Case("Yes", YamlBuilder.YamlType.boolean),
		Case("YES", YamlBuilder.YamlType.boolean),
		Case("no", YamlBuilder.YamlType.boolean),
		Case("No", YamlBuilder.YamlType.boolean),
		Case("NO", YamlBuilder.YamlType.boolean),
		Case("on", YamlBuilder.YamlType.boolean),
		Case("On", YamlBuilder.YamlType.boolean),
		Case("ON", YamlBuilder.YamlType.boolean),
		Case("off", YamlBuilder.YamlType.boolean),
		Case("Off", YamlBuilder.YamlType.boolean),
		Case("OFF", YamlBuilder.YamlType.boolean),
		// 整数(10進)
		Case("0", YamlBuilder.YamlType.integer),
		Case("123", YamlBuilder.YamlType.integer),
		Case("-123", YamlBuilder.YamlType.integer),
		Case("+123", YamlBuilder.YamlType.integer),
		// 整数(16進)
		Case("0x1A", YamlBuilder.YamlType.integer),
		Case("0xFF", YamlBuilder.YamlType.integer),
		Case("-0x1A", YamlBuilder.YamlType.integer),
		// 整数(8進、1.2形式 `0o`)
		Case("0o17", YamlBuilder.YamlType.integer),
		// 整数(8進、1.1レガシー形式、Y10)
		Case("017", YamlBuilder.YamlType.integer),
		Case("0777", YamlBuilder.YamlType.integer),
		// 8/9を含むため8進とはみなされないが、10進としては有効(先頭ゼロ付き10進)
		Case("0779", YamlBuilder.YamlType.integer),
		// 整数(2進)
		Case("0b101", YamlBuilder.YamlType.integer),
		Case("0B101", YamlBuilder.YamlType.integer),
		// 浮動小数点数
		Case("3.14", YamlBuilder.YamlType.floating),
		Case("-3.14", YamlBuilder.YamlType.floating),
		Case(".5", YamlBuilder.YamlType.floating),
		Case("5.", YamlBuilder.YamlType.floating),
		Case("1e10", YamlBuilder.YamlType.floating),
		Case("1.5e-10", YamlBuilder.YamlType.floating),
		Case(".inf", YamlBuilder.YamlType.floating),
		Case("-.inf", YamlBuilder.YamlType.floating),
		Case("+.inf", YamlBuilder.YamlType.floating),
		Case(".Inf", YamlBuilder.YamlType.floating),
		Case(".INF", YamlBuilder.YamlType.floating),
		Case(".nan", YamlBuilder.YamlType.floating),
		Case(".NaN", YamlBuilder.YamlType.floating),
		Case(".NAN", YamlBuilder.YamlType.floating),
		// 文字列(数値・真偽値・nullのどれにも該当しない)
		Case("hello", YamlBuilder.YamlType.string),
		Case("yesno", YamlBuilder.YamlType.string),
		Case("1.2.3", YamlBuilder.YamlType.string),
		Case("-", YamlBuilder.YamlType.string),
		Case("+", YamlBuilder.YamlType.string),
		Case("0x", YamlBuilder.YamlType.string),
		Case("0xGG", YamlBuilder.YamlType.string),
		Case("+.nan", YamlBuilder.YamlType.string), // .nanは符号付きを認めない
	];
	foreach (c; cases)
	{
		YamlBuilder.YamlValue dst;
		auto resolved = builder.resolveScalarTypeImpl(dst, c.raw);
		assert(resolved == c.expected,
			"raw='" ~ c.raw ~ "' expected=" ~ c.expected.to!string ~ " actual=" ~ resolved.to!string);
		assert(dst.type == c.expected);
	}
}

// resolveScalarTypeImpl - 数値の実値と基数の検証
@safe unittest
{
	YamlBuilder builder;
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "0x1A");
		assert(dst.get!int == 26);
		assert(dst.asInteger.base == IntegerBase.hex);
	}
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "017");
		assert(dst.get!int == 15); // 8進の017は10進で15
		assert(dst.asInteger.base == IntegerBase.octal);
	}
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "0o17");
		assert(dst.get!int == 15);
		assert(dst.asInteger.base == IntegerBase.octal);
	}
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "0b101");
		assert(dst.get!int == 5);
		assert(dst.asInteger.base == IntegerBase.binary);
	}
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "-42");
		assert(dst.get!int == -42);
	}
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, "3.14");
		import std.math : approxEqual = isClose;
		assert(approxEqual(dst.get!double, 3.14));
	}
	{
		import std.math : isInfinity, isNaN;
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, ".inf");
		assert(isInfinity(dst.get!double));
		YamlBuilder.YamlValue dst2;
		builder.resolveScalarTypeImpl(dst2, "-.inf");
		assert(isInfinity(dst2.get!double) && dst2.get!double < 0);
		YamlBuilder.YamlValue dst3;
		builder.resolveScalarTypeImpl(dst3, ".nan");
		assert(isNaN(dst3.get!double));
	}
}

// resolveScalarTypeImpl - 巨大な符号なし整数はYamlUIntegerに解決される
@safe unittest
{
	YamlBuilder builder;
	YamlBuilder.YamlValue dst;
	// long.max を超える値
	auto resolved = builder.resolveScalarTypeImpl(dst, "18446744073709551615"); // ulong.max
	assert(resolved == YamlBuilder.YamlType.uinteger);
	assert(dst.asUInteger.value == ulong.max);
}

// resolveScalarTypeImpl - raw フィールドが常に元のテキストを保持する
@safe unittest
{
	YamlBuilder builder;
	foreach (raw; ["0x1A", "017", "3.14", "true", "~", "hello"])
	{
		YamlBuilder.YamlValue dst;
		builder.resolveScalarTypeImpl(dst, raw);
		final switch (dst.type)
		{
		case YamlBuilder.YamlType.integer:   assert(dst.asInteger.raw[] == raw); break;
		case YamlBuilder.YamlType.uinteger:  assert(dst.asUInteger.raw[] == raw); break;
		case YamlBuilder.YamlType.floating:  assert(dst.asFloatingPoint.raw[] == raw); break;
		case YamlBuilder.YamlType.boolean:   assert(dst.asBoolean.raw[] == raw); break;
		case YamlBuilder.YamlType.string:    assert(dst.asString.raw[] == raw); break;
		case YamlBuilder.YamlType.nullfied:  assert(dst.asNull.raw[] == raw); break;
		case YamlBuilder.YamlType.undefined:
		case YamlBuilder.YamlType.alias_:
		case YamlBuilder.YamlType.sequence:
		case YamlBuilder.YamlType.mapping:
			assert(0, "unexpected type for scalar resolution");
		}
	}
}

// skipFlowSpacingImpl - 空白・タブ・改行の読み飛ばし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	auto consumed = builder.skipFlowSpacingImpl("   \t\nabc", line, col);
	assert(consumed == 5);
	assert(line == 2);
	assert(col == 1);
}

// parseFlowSequenceImpl - 空のflowシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseFlowSequenceImpl(dst, "[]", line, col, 0);
	assert(consumed == 2);
	assert(dst.type == YamlBuilder.YamlType.sequence);
	assert(dst.asSequence.value.length == 0);
	assert(dst.asSequence.style == CollectionStyle.flow);
	assert(dst.asSequence.singleLine);
	assert(!dst.asSequence.trailingComma);
}

// parseFlowSequenceImpl - 単純な数値要素のシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseFlowSequenceImpl(dst, "[1, 2, 3]", line, col, 0);
	assert(consumed == 9);
	assert(dst.asSequence.value.length == 3);
	assert(dst.getElement!int(0) == 1);
	assert(dst.getElement!int(1) == 2);
	assert(dst.getElement!int(2) == 3);
	assert(!dst.asSequence.trailingComma);
}

// parseFlowSequenceImpl - ケツカンマを許容する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1, 2, 3,]", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(dst.asSequence.trailingComma);
}

// parseFlowSequenceImpl - ネストしたflowシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1, [2, 3], 4]", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(dst.getElement!int(0) == 1);
	assert(dst.getElement!int(2) == 4);
	auto nested = dst.asSequence.value[1];
	assert(nested.type == YamlBuilder.YamlType.sequence);
	assert(nested.getElement!int(0) == 2);
	assert(nested.getElement!int(1) == 3);
}

// parseFlowSequenceImpl - plain/single/doubleクォート要素が混在するシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, `[a, 'b', "c"]`, line, col, 0);
	assert(dst.getElement!string(0) == "a");
	assert(dst.getElement!string(1) == "b");
	assert(dst.getElement!string(2) == "c");
	assert(dst.asSequence.value[0].asString.style == ScalarStyle.plain);
	assert(dst.asSequence.value[1].asString.style == ScalarStyle.singleQuoted);
	assert(dst.asSequence.value[2].asString.style == ScalarStyle.doubleQuoted);
}

// parseFlowSequenceImpl - 複数行にまたがる場合はsingleLineがfalseになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1,\n 2,\n 3]", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(!dst.asSequence.singleLine);
}

// parseFlowSequenceImpl - 1行に収まる場合はsingleLineがtrueのままになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1, 2, 3]", line, col, 0);
	assert(dst.asSequence.singleLine);
}

// parseFlowSequenceImpl - 未終端の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowSequenceImpl(dst, "[1, 2", line, col, 0));
}

// parseFlowSequenceImpl - 先頭がいきなり`,`の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowSequenceImpl(dst, "[,1]", line, col, 0));
}

// parseFlowMappingImpl - 空のflowマッピング
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseFlowMappingImpl(dst, "{}", line, col, 0);
	assert(consumed == 2);
	assert(dst.type == YamlBuilder.YamlType.mapping);
	assert(dst.asMapping.value.length == 0);
	assert(dst.asMapping.style == CollectionStyle.flow);
}

// parseFlowMappingImpl - 単純なキー・値ペア
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseFlowMappingImpl(dst, "{a: 1, b: 2}", line, col, 0);
	assert(consumed == 12);
	assert(dst.asMapping.value.length == 2);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

// parseFlowMappingImpl - ケツカンマを許容する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{a: 1, b: 2,}", line, col, 0);
	assert(dst.asMapping.value.length == 2);
	assert(dst.asMapping.trailingComma);
}

// parseFlowMappingImpl - 値を省略したエントリは暗黙のnullとして解決される
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{a, b: 2}", line, col, 0);
	assert(dst.asMapping.value.length == 2);
	assert(dst.asMapping["a"].type == YamlBuilder.YamlType.nullfied);
	assert(dst.getValue!int("b") == 2);
}

// parseFlowMappingImpl - キーを省略した`e-node`エントリは空文字列キーになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{: 1}", line, col, 0);
	assert(dst.asMapping.value.length == 1);
	assert(dst.asMapping[""].get!int == 1);
}

// parseFlowMappingImpl - キーの重複はパースエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseFlowMappingImpl(dst, "{a: 1, a: 2}", line, col, 0));
}

// parseFlowMappingImpl - 非スカラーキーは非対応としてエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowMappingImpl(dst, "{[1]: 2}", line, col, 0));
}

// parseFlowMappingImpl - シングルクォート・ダブルクォートキー
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, `{'a': 1, "b": 2}`, line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

// parseFlowMappingImpl - flowシーケンス・flowマッピングの相互ネスト
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{a: [1, 2], b: {c: 3}}", line, col, 0);
	auto aSeq = dst.asMapping["a"];
	assert(aSeq.type == YamlBuilder.YamlType.sequence);
	assert(aSeq.getElement!int(0) == 1);
	assert(aSeq.getElement!int(1) == 2);
	auto bMap = dst.asMapping["b"];
	assert(bMap.type == YamlBuilder.YamlType.mapping);
	assert(bMap.getValue!int("c") == 3);
}

// parseFlowMappingImpl - 未終端の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowMappingImpl(dst, "{a: 1", line, col, 0));
}

// parseFlowNodeImpl - トップレベルからflowシーケンス/マッピングへ振り分ける
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		auto consumed = builder.parseFlowNodeImpl(dst, "[1, 2]", line, col, 0);
		assert(consumed == 6);
		assert(dst.type == YamlBuilder.YamlType.sequence);
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		auto consumed = builder.parseFlowNodeImpl(dst, "{a: 1}", line, col, 0);
		assert(consumed == 6);
		assert(dst.type == YamlBuilder.YamlType.mapping);
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		auto consumed = builder.parseFlowNodeImpl(dst, "42", line, col, 0);
		assert(consumed == 2);
		assert(dst.type == YamlBuilder.YamlType.integer);
	}
}

// isBlockSequenceIndicatorImpl - `-`項目インジケータの判定
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isBlockSequenceIndicatorImpl("- a"));
	assert(builder.isBlockSequenceIndicatorImpl("-"));
	assert(builder.isBlockSequenceIndicatorImpl("-\n"));
	assert(!builder.isBlockSequenceIndicatorImpl("-5"));
	assert(!builder.isBlockSequenceIndicatorImpl("-foo"));
	assert(!builder.isBlockSequenceIndicatorImpl("--- doc"));
	assert(!builder.isBlockSequenceIndicatorImpl("abc"));
	assert(!builder.isBlockSequenceIndicatorImpl(""));
}

// isExplicitKeyIndicatorImpl - `?`明示キーインジケータの判定
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isExplicitKeyIndicatorImpl("? a"));
	assert(builder.isExplicitKeyIndicatorImpl("?"));
	assert(!builder.isExplicitKeyIndicatorImpl("?a"));
	assert(!builder.isExplicitKeyIndicatorImpl("abc"));
}

// lineHasMappingColonImpl - コロン先読みによるマッピング判定
@safe unittest
{
	YamlBuilder builder;
	assert(builder.lineHasMappingColonImpl("key: value"));
	assert(builder.lineHasMappingColonImpl("key:"));
	assert(builder.lineHasMappingColonImpl("'quoted key': value"));
	assert(builder.lineHasMappingColonImpl(`"quoted key": value`));
	assert(builder.lineHasMappingColonImpl("url: http://example.com"));
	assert(!builder.lineHasMappingColonImpl("just a plain scalar"));
	assert(!builder.lineHasMappingColonImpl("not:mapping"));
	assert(!builder.lineHasMappingColonImpl("no colon here\nkey: value"));
	assert(!builder.lineHasMappingColonImpl("# key: value"));
	assert(!builder.lineHasMappingColonImpl("value # trailing: comment"));
}

// skipBlankAndCommentLinesImpl - 空行・コメント行の読み飛ばし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	auto consumed = builder.skipBlankAndCommentLinesImpl("\n\n# comment\n  # indented comment\nkey: value", line, col);
	assert(line == 5);
	assert(col == 1);
	assert("\n\n# comment\n  # indented comment\nkey: value"[consumed .. $] == "key: value");
}

// skipBlankAndCommentLinesImpl - コメント本文とインデント量を`_pendingComments`に蓄積する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	builder.skipBlankAndCommentLinesImpl("\n\n# comment\n  # indented comment\nkey: value", line, col);
	assert(builder._pendingComments.length == 2);
	assert(cast(string)builder._pendingComments[0].text == " comment");
	assert(builder._pendingComments[0].indentLen == 0);
	assert(cast(string)builder._pendingComments[1].text == " indented comment");
	assert(builder._pendingComments[1].indentLen == 2);
}

// parseBlockSequenceImpl - 単純なblockシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseBlockSequenceImpl(dst, "- a\n- b\n- c", line, col, 0);
	assert(consumed == 11);
	assert(dst.type == YamlBuilder.YamlType.sequence);
	assert(dst.asSequence.style == CollectionStyle.block);
	assert(dst.getElement!string(0) == "a");
	assert(dst.getElement!string(1) == "b");
	assert(dst.getElement!string(2) == "c");
}

// parseBlockMappingImpl - 単純なblockマッピング
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseBlockMappingImpl(dst, "a: 1\nb: 2\nc: 3", line, col, 0);
	assert(consumed == 14);
	assert(dst.type == YamlBuilder.YamlType.mapping);
	assert(dst.asMapping.style == CollectionStyle.block);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
	assert(dst.getValue!int("c") == 3);
}

// parseBlockNodeImpl - より深いインデントによるネストしたマッピング
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1\nb:\n  c: 2\n  d: 3\ne: 4", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("e") == 4);
	auto b = dst.asMapping["b"];
	assert(b.type == YamlBuilder.YamlType.mapping);
	assert(b.getValue!int("c") == 2);
	assert(b.getValue!int("d") == 3);
}

// parseBlockNodeImpl - マッピング値としてのシーケンスはキーと同じインデントでもよい
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "items:\n- a\n- b\nkey2: c", line, col, 0);
	auto items = dst.asMapping["items"];
	assert(items.type == YamlBuilder.YamlType.sequence);
	assert(items.getElement!string(0) == "a");
	assert(items.getElement!string(1) == "b");
	assert(dst.getValue!string("key2") == "c");
}

// parseBlockNodeImpl - マッピング値としてのシーケンスはより深いインデントでもよい
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "items:\n  - a\n  - b\nkey2: c", line, col, 0);
	auto items = dst.asMapping["items"];
	assert(items.type == YamlBuilder.YamlType.sequence);
	assert(items.getElement!string(0) == "a");
	assert(items.getElement!string(1) == "b");
	assert(dst.getValue!string("key2") == "c");
}

// parseBlockNodeImpl - blockシーケンス項目としてのインラインマッピング（`- key: value`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto src = "- key1: value1\n  key2: value2\n- key1: value3\n  key2: value4";
	auto consumed = builder.parseBlockNodeImpl(dst, src, line, col, 0);
	assert(consumed == src.length);
	assert(dst.type == YamlBuilder.YamlType.sequence);
	assert(dst.asSequence.value.length == 2);
	auto item0 = dst.asSequence.value[0];
	assert(item0.type == YamlBuilder.YamlType.mapping);
	assert(item0.getValue!string("key1") == "value1");
	assert(item0.getValue!string("key2") == "value2");
	auto item1 = dst.asSequence.value[1];
	assert(item1.getValue!string("key1") == "value3");
	assert(item1.getValue!string("key2") == "value4");
}

// parseBlockNodeImpl - コンパクトなネストシーケンス（`- - 1`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- - 1\n  - 2\n- 3", line, col, 0);
	assert(dst.asSequence.value.length == 2);
	auto inner = dst.asSequence.value[0];
	assert(inner.type == YamlBuilder.YamlType.sequence);
	assert(inner.getElement!int(0) == 1);
	assert(inner.getElement!int(1) == 2);
	assert(dst.getElement!int(1) == 3);
}

// parseBlockNodeImpl - マッピング値としてのflowコレクション
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: [1, 2, 3]\nb: {x: 1, y: 2}", line, col, 0);
	auto a = dst.asMapping["a"];
	assert(a.type == YamlBuilder.YamlType.sequence);
	assert(a.getElement!int(0) == 1);
	assert(a.getElement!int(2) == 3);
	auto b = dst.asMapping["b"];
	assert(b.type == YamlBuilder.YamlType.mapping);
	assert(b.getValue!int("x") == 1);
	assert(b.getValue!int("y") == 2);
}

// parseBlockNodeImpl - マッピング値としてのblockリテラルスカラー（同一行`|`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: |\n  line1\n  line2\nb: 2", line, col, 0);
	assert(dst.getValue!string("a") == "line1\nline2\n");
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - マッピング値としてのblockリテラルスカラー（独立行`|`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a:\n  |\n    line1\n    line2\nb: 2", line, col, 0);
	assert(dst.getValue!string("a") == "line1\nline2\n");
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - 深いネスト構造（マッピング・シーケンスの入れ子）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseBlockNodeImpl(dst,
		"a:\n  b:\n    c:\n      - 1\n      - 2\n  d: 3", line, col, 0);
	assert(consumed == "a:\n  b:\n    c:\n      - 1\n      - 2\n  d: 3".length);
	auto a = dst.asMapping["a"];
	auto b = a.asMapping["b"];
	auto c = b.asMapping["c"];
	assert(c.type == YamlBuilder.YamlType.sequence);
	assert(c.getElement!int(0) == 1);
	assert(c.getElement!int(1) == 2);
	assert(a.getValue!int("d") == 3);
}

// parseBlockNodeImpl - 暗黙のnull値
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a:\nb: 2", line, col, 0);
	assert(dst.asMapping["a"].type == YamlBuilder.YamlType.nullfied);
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - シングル/ダブルクォートキー
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "'a': 1\n\"b\": 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - 空行・コメント行の混在
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1\n\n# comment\nb: 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - 値の直後の行末コメント
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1 # comment\nb: 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

// parseBlockNodeImpl - シーケンス項目間のコメント行
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- a\n# comment\n- b\n\n- c", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(dst.getElement!string(0) == "a");
	assert(dst.getElement!string(1) == "b");
	assert(dst.getElement!string(2) == "c");
}

// parseBlockNodeImpl - 負数はシーケンスインジケータと誤認識されない
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- -5\n- -3.14", line, col, 0);
	assert(dst.getElement!int(0) == -5);
	assert(dst.getElement!double(1) == -3.14);
}

// parseBlockNodeImpl - 裸のスカラードキュメント
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	auto consumed = builder.parseBlockNodeImpl(dst, "hello world", line, col, 0);
	assert(consumed == 11);
	assert(dst.type == YamlBuilder.YamlType.string);
	assert(dst.get!string == "hello world");
}

// parseBlockNodeImpl - キーの重複はパースエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\na: 2", line, col, 0));
}

// parseBlockNodeImpl - 非スカラーキーは非対応としてエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseBlockNodeImpl(dst, "a: 1\n[1,2]: value", line, col, 0));
}

// parseBlockNodeImpl - 明示キー（`?`）は非対応としてエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "? a\n: 1", line, col, 0));
}

// parseBlockNodeImpl - quoted/flow値の直後の同一行の残存内容はエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		assertThrown!YamlParseException(
			builder.parseBlockNodeImpl(dst, "a: \"hi\"junk\nb: 2", line, col, 0));
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		assertThrown!YamlParseException(
			builder.parseBlockNodeImpl(dst, "a: [1,2]junk\nb: 2", line, col, 0));
	}
}

// parseBlockNodeImpl - plainスカラーの折り畳みが行途中の埋め込みセパレータで
// 終了した場合、残存内容はエラーになる（クラッシュせず明示的なエラーになることの回帰テスト）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\n    b: 2", line, col, 0));
}

// parseBlockNodeImpl - quoted値の後に続く想定外のインデント上昇はエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseBlockNodeImpl(dst, "a: \"quoted\"\n    b: 2", line, col, 0));
}

// parseBlockNodeImpl - シーケンスとマッピングを同一インデントで混在させるとエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\n- item", line, col, 0));
}

// parseBlockNodeImpl - インデントにタブ文字が混入するとエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a:\n\tb: 1", line, col, 0));
}

// parseCommentTextImpl - `#`から行末までのコメント本文を読み取る
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String text;
	auto consumed = builder.parseCommentTextImpl(text, "# hello world\nnext", col);
	assert(consumed == 13);
	assert(cast(string)text == " hello world");
	assert(col == 14);
}

// parseCommentTextImpl - 空コメント（`#`のみ）
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String text;
	auto consumed = builder.parseCommentTextImpl(text, "#\nnext", col);
	assert(consumed == 1);
	assert(cast(string)text == "");
}

// leading comment(ルール1) - マッピングの最初のキーの前に書かれたコメントは
// マッピング自身のleading commentになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "# header\na: 1", line, col, 0);
	assert(dst.getCommentLength() == 1);
	assert(dst.getComment(0) == " header");
	assert(dst.getValue!int("a") == 1);
}

// leading comment(ルール1) - 複数行のコメントは順序を保って蓄積される
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "# line1\n# line2\nkey: value", line, col, 0);
	assert(dst.getCommentLength() == 2);
	assert(dst.getComment(0) == " line1");
	assert(dst.getComment(1) == " line2");
}

// leading comment(ルール1) - 空行を1つ以上挟んでも蓄積が継続する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "# c1\n\n# c2\nkey: value", line, col, 0);
	assert(dst.getCommentLength() == 2);
	assert(dst.getComment(0) == " c1");
	assert(dst.getComment(1) == " c2");
}

// leading comment(ルール1) - シーケンス項目の前のコメントはその項目のleading commentになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- a\n# for b\n- b", line, col, 0);
	assert(dst.asSequence.value[0].getCommentLength() == 0);
	auto item1 = dst.asSequence.value[1];
	assert(item1.getCommentLength() == 1);
	assert(item1.getComment(0) == " for b");
}

// leading comment(ルール1) - ネストしたコレクション自身の前のコメントは
// そのコレクション自身のleading commentになる（先頭要素個別ではなく）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "key1:\n  # comment about the nested map\n  a: 1\n  b: 2", line, col, 0);
	auto nested = dst.asMapping["key1"];
	assert(nested.getCommentLength() == 1);
	assert(nested.getComment(0) == " comment about the nested map");
	assert(nested.asMapping["a"].getCommentLength() == 0);
}

// trailing comment(ルール2) - 値と同一行のコメントはその値のtrailing commentになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1 # trailing\nb: 2", line, col, 0);
	auto a = dst.asMapping["a"];
	assert(a.getCommentLength() == 1);
	assert(a.isTrailingComment(0));
	assert(a.getComment(0) == " trailing");
	assert(dst.getValue!int("b") == 2);
}

// leading commentとtrailing commentが同一ノードに共存する場合、
// 配列内の順序はleadingが先・trailingが最後になる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1\n# leading for b\nb: 2 # trailing for b\nc: 3", line, col, 0);
	auto b = dst.asMapping["b"];
	assert(b.getCommentLength() == 2);
	assert(b.isLineComment(0));
	assert(b.getComment(0) == " leading for b");
	assert(b.isTrailingComment(1));
	assert(b.getComment(1) == " trailing for b");
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("c") == 3);
}

// flowコレクションの値全体に対する末尾コメントもtrailing commentになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: [1,2] # comment on the list\nb: 2", line, col, 0);
	auto a = dst.asMapping["a"];
	assert(a.type == YamlBuilder.YamlType.sequence);
	assert(a.getCommentLength() == 1);
	assert(a.isTrailingComment(0));
	assert(a.getComment(0) == " comment on the list");
}

// dangling comment(ルール3) - ファイル末尾のコメントは、それを含む
// コレクション自身のtrailingCommentsになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "mapping:\n  a: 1\n  b: 2\n  # final comment", line, col, 0);
	auto mapping = dst.asMapping["mapping"];
	assert(mapping.asMapping.trailingComments.length == 1);
	assert(mapping.asMapping.trailingComments[0].match!(
		(ref const(YamlBuilder.YamlValue.LineComment) c) => cast(string)c.value,
		(ref const(YamlBuilder.YamlValue.TrailingComment) c) => cast(string)c.value)
		== " final comment");
}

// dangling comment(ルール3・4) - より浅いインデントのコメントは
// 内側のコレクションのdangling commentにはならず、後続の実トークンの
// leading commentとして正しく外側へ委譲される
// （gopkg.in/yaml.v3 Issue #497 Case 1と同種の誤帰属を防ぐ回帰テスト）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst,
		"mapping:\n  a: 1\n  b: 2\n# comment for outer\notherkey: value", line, col, 0);
	auto mapping = dst.asMapping["mapping"];
	assert(mapping.asMapping.trailingComments.length == 0);
	auto otherkey = dst.asMapping["otherkey"];
	assert(otherkey.getCommentLength() == 1);
	assert(otherkey.getComment(0) == " comment for outer");
}

// dangling comment - 深さの異なる複数のdangling commentが
// それぞれ正しい階層に帰属する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst,
		"a:\n  b:\n    c: 1\n    # dangling for b\n  # dangling for a\nd: 2", line, col, 0);
	auto a = dst.asMapping["a"];
	auto b = a.asMapping["b"];
	assert(b.asMapping.trailingComments.length == 1);
	assert(b.asMapping.trailingComments[0].match!(
		(ref const(YamlBuilder.YamlValue.LineComment) c) => cast(string)c.value,
		(ref const(YamlBuilder.YamlValue.TrailingComment) c) => cast(string)c.value)
		== " dangling for b");
	assert(a.asMapping.trailingComments.length == 1);
	assert(a.asMapping.trailingComments[0].match!(
		(ref const(YamlBuilder.YamlValue.LineComment) c) => cast(string)c.value,
		(ref const(YamlBuilder.YamlValue.TrailingComment) c) => cast(string)c.value)
		== " dangling for a");
	assert(dst.getValue!int("d") == 2);
}

// flowマッピング/flowシーケンス内のコメント(leading・dangling)
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseFlowMappingImpl(dst, "{\n  # comment for a\n  a: 1\n}", line, col, 0);
		auto a = dst.asMapping["a"];
		assert(a.getCommentLength() == 1);
		assert(a.getComment(0) == " comment for a");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseFlowMappingImpl(dst, "{a: 1,\n b: 2\n # dangling\n}", line, col, 0);
		assert(dst.getValue!int("a") == 1);
		assert(dst.getValue!int("b") == 2);
		assert(dst.asMapping.trailingComments.length == 1);
		assert(dst.asMapping.trailingComments[0].match!(
			(ref const(YamlBuilder.YamlValue.LineComment) c) => cast(string)c.value,
			(ref const(YamlBuilder.YamlValue.TrailingComment) c) => cast(string)c.value)
			== " dangling");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseFlowSequenceImpl(dst, "[1, 2, # trailing in flow\n]", line, col, 0);
		assert(dst.asSequence.trailingComments.length == 1);
	}
}

// plainスカラーの複数行折り畳みは、コメントのみの継続行では折り畳みを
// 行わず、その手前でスカラーを終了させる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "key: this is\n  a value\n  # comment here\nnext: 2", line, col, 0);
	assert(dst.getValue!string("key") == "this is a value");
	auto next = dst.asMapping["next"];
	assert(next.get!int == 2);
	assert(next.getCommentLength() == 1);
	assert(next.getComment(0) == " comment here");
}

// コメントを挟まない通常の複数行折り畳みは引き続き正しく動作する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "key: this is\n  a folded value\nnext: 2", line, col, 0);
	assert(dst.getValue!string("key") == "this is a folded value");
	assert(dst.getValue!int("next") == 2);
}

// deepCopy - スカラー値は等しいがコレクションは独立したコピーになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a:\n  - 1\n  - 2\nb: hello", line, col, 0);
	auto copy = builder.deepCopy(dst);
	assert(copy.getValue!string("b") == "hello");
	auto origA = dst.asMapping["a"];
	auto copyA = copy.asMapping["a"];
	assert(copyA.getElement!int(0) == 1);
	assert(copyA.getElement!int(1) == 2);
	assert(&origA.asSequence.value[0] !is &copyA.asSequence.value[0]);
}

// parseAnchorNameImpl - 名前の終端判定（空白・flowインジケータ）
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String name;
	auto consumed = builder.parseAnchorNameImpl(name, "anchor rest", col);
	assert(consumed == 6);
	assert(cast(string)name == "anchor");
	assert(col == 7);
}

// parseAnchorNameImpl - flowコンテキストの区切り文字（`,`/`]`/`}`）で終端する
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String name;
	auto consumed = builder.parseAnchorNameImpl(name, "x,rest", col);
	assert(consumed == 1);
	assert(cast(string)name == "x");
}

// 単純なスカラーへのアンカー・エイリアス解決
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &anchor 1\nb: *anchor", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	auto b = dst.asMapping["b"];
	assert(b.type == YamlBuilder.YamlType.alias_);
	assert(cast(string)b.asAlias.value == "anchor");
	assert(b.get!int == 1);
}

// コレクション全体へのエイリアスはdeepCopyにより独立したコピーになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &seq [1, 2, 3]\nb: *seq", line, col, 0);
	auto a = dst.asMapping["a"];
	auto b = dst.asMapping["b"];
	assert(b.getElement!int(0) == 1);
	assert(b.getElement!int(2) == 3);
	assert(&a.asSequence.value[0] !is &b.dereference().asSequence.value[0]);
}

// 未定義アンカーの参照は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: *undefined", line, col, 0));
}

// 同名アンカーの再定義は後勝ちになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &x 1\nb: &x 2\nc: *x", line, col, 0);
	assert(dst.asMapping["c"].get!int == 2);
}

// 同一アンカーへの複数のエイリアスはそれぞれ独立したコピーになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &x [1,2]\nb: *x\nc: *x", line, col, 0);
	auto b = dst.asMapping["b"];
	auto c = dst.asMapping["c"];
	assert(b.getElement!int(0) == 1);
	assert(c.getElement!int(0) == 1);
	assert(&b.dereference().asSequence.value[0] !is &c.dereference().asSequence.value[0]);
}

// flowコレクション内でのアンカー・エイリアス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "{a: &x 1, b: *x}", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.asMapping["b"].get!int == 1);
}

// マッピング値としてのネストしたコレクションへのアンカー
// （アンカー自身が同一行の場合と独立行の場合の両方）
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: &anchor\n  x: 1\n  y: 2\nb: *anchor", line, col, 0);
		assert(dst.asMapping["a"].getValue!int("x") == 1);
		assert(dst.asMapping["b"].getValue!int("y") == 2);
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a:\n  &anchor\n  x: 1\nb: *anchor", line, col, 0);
		assert(dst.asMapping["a"].getValue!int("x") == 1);
		assert(dst.asMapping["b"].getValue!int("x") == 1);
	}
}

// シーケンス項目へのアンカー・エイリアス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- &a 1\n- *a", line, col, 0);
	assert(dst.getElement!int(0) == 1);
	assert(dst.asSequence.value[1].get!int == 1);
}

// アンカーの直後に続くplainスカラーの複数行折り畳みは、アンカー自身の
// 列位置ではなく、それを囲むエントリ自身のインデントを基準に判定される
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- &a value\n  continued\n- other", line, col, 0);
	assert(dst.getElement!string(0) == "value continued");
	assert(dst.getElement!string(1) == "other");
}

// エイリアスがさらにエイリアスを指す連鎖
// （アンカーをエイリアスノード自体に付けた場合）も`dereference()`で
// 最終的な実体まで再帰的に辿れる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &x 1\nb: &y *x\nc: *y", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.asMapping["b"].get!int == 1);
	assert(dst.asMapping["c"].get!int == 1);
}

// 空のアンカー名・エイリアス名は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: &\nb: 2", line, col, 0));
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: *\nb: 2", line, col, 0));
	}
}

// parseTagImpl - セカンダリタグハンドル（`!!str`等）は空白まで読み取る
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue.String tag;
	auto consumed = builder.parseTagImpl(tag, "!!str rest", line, col);
	assert(consumed == 5);
	assert(cast(string)tag == "!!str");
	assert(col == 6);
}

// parseTagImpl - verbatim形式（`!<...>`）は閉じの`>`まで読み取る
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue.String tag;
	auto consumed = builder.parseTagImpl(tag, "!<tag:example.com,2000:app/mytype> rest", line, col);
	assert(consumed == 34);
	assert(cast(string)tag == "!<tag:example.com,2000:app/mytype>");
}

// parseTagImpl - verbatim形式で閉じの`>`が見つからない場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue.String tag;
	assertThrown!YamlParseException(builder.parseTagImpl(tag, "!<unterminated", line, col));
}

// 明示タグは値の型解決に使わず、保持のみされる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: !!str 42", line, col, 0);
	auto a = dst.asMapping["a"];
	assert(a.tagName.get == "!!str");
	// !!strタグが付いていても型解決には使わないため、42は引き続き整数として解決される
	assert(a.type == YamlBuilder.YamlType.integer);
	assert(a.get!int == 42);
}

// プライマリタグ・裸の非specificタグ
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: !mytag value", line, col, 0);
		auto a = dst.asMapping["a"];
		assert(a.tagName.get == "!mytag");
		assert(a.get!string == "value");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: ! value", line, col, 0);
		assert(dst.asMapping["a"].tagName.get == "!");
	}
}

// タグはネストしたコレクションにも付与できる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: !!map\n  x: 1\n  y: 2", line, col, 0);
	auto a = dst.asMapping["a"];
	assert(a.tagName.get == "!!map");
	assert(a.type == YamlBuilder.YamlType.mapping);
	assert(a.getValue!int("x") == 1);
	assert(a.getValue!int("y") == 2);
}

// タグとアンカーはどちらの順序でも組み合わせられる
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: !!str &anchor hello\nb: *anchor", line, col, 0);
		auto a = dst.asMapping["a"];
		assert(a.tagName.get == "!!str");
		assert(a.get!string == "hello");
		assert(dst.asMapping["b"].get!string == "hello");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: &anchor !!str hello\nb: *anchor", line, col, 0);
		auto a = dst.asMapping["a"];
		assert(a.tagName.get == "!!str");
		assert(a.get!string == "hello");
		assert(dst.asMapping["b"].get!string == "hello");
	}
}

// flowコンテキストでのタグ（スカラー・flowシーケンスへの付与）
@safe unittest
{
	YamlBuilder builder;
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "{a: !!int 5, b: !!str text}", line, col, 0);
		assert(dst.asMapping["a"].tagName.get == "!!int");
		assert(dst.asMapping["b"].tagName.get == "!!str");
	}
	{
		size_t line = 1, col = 1;
		YamlBuilder.YamlValue dst;
		builder.parseBlockNodeImpl(dst, "a: !!seq [1, 2, 3]", line, col, 0);
		auto a = dst.asMapping["a"];
		assert(a.tagName.get == "!!seq");
		assert(a.getElement!int(1) == 2);
	}
}

// シーケンス項目それぞれへのタグ付与
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- !!str 1\n- !!int 2", line, col, 0);
	assert(dst.asSequence.value[0].tagName.get == "!!str");
	assert(dst.asSequence.value[1].tagName.get == "!!int");
}

// parse() - 単純なマッピング・シーケンス・裸のスカラー
@safe unittest
{
	YamlBuilder builder;
	{
		auto result = builder.parse("a: 1\nb: 2");
		assert(result.type == YamlBuilder.YamlType.mapping);
		assert(result.getValue!int("a") == 1);
	}
	{
		auto result = builder.parse("- 1\n- 2");
		assert(result.type == YamlBuilder.YamlType.sequence);
		assert(result.getElement!int(0) == 1);
	}
	{
		auto result = builder.parse("hello world");
		assert(result.type == YamlBuilder.YamlType.string);
		assert(result.get!string == "hello world");
	}
}

// parse() - 先頭のBOMは読み飛ばされる
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("\uFEFFa: 1\nb: 2");
	assert(result.type == YamlBuilder.YamlType.mapping);
	assert(result.getValue!int("a") == 1);
	assert(result.getValue!int("b") == 2);
}

// parse() - ストリーム先頭以外のBOMはエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("a: 1\nb: \uFEFF2"));
}

// parse() - 複数ドキュメント構文（行頭`---`/`...`）は明示的にエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("---\na: 1"));
	assertThrown!YamlParseException(builder.parse("a: 1\n..."));
	assertThrown!YamlParseException(builder.parse("a: 1\n---\nb: 2"));
	assertThrown!YamlParseException(builder.parse("- 1\n- 2\n---\n- 3"));
}

// parse() - `%`ディレクティブ行は明示的にエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("%YAML 1.2\n---\na: 1"));
}

// parse() - 4個以上のダッシュはドキュメント区切りと誤認識されない
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("---- 1");
	assert(result.type == YamlBuilder.YamlType.string);
}

// parse() - ルートノードの後に空行・コメントのみが続く場合は許容される
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("a: 1\n\n# comment\n");
	assert(result.getValue!int("a") == 1);
}

// parse() - ルートノードの後に予期しない内容が続く場合はエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("a: 1\nrandom garbage"));
}

// parse() - 空・空白のみ・コメントのみのドキュメントはnullになる
@safe unittest
{
	YamlBuilder builder;
	assert(builder.parse("").type == YamlBuilder.YamlType.nullfied);
	assert(builder.parse("   \n  \n").type == YamlBuilder.YamlType.nullfied);
	assert(builder.parse("# just a comment\n").type == YamlBuilder.YamlType.nullfied);
}

// parse() - 行頭以外の`%`は通常のplainスカラー内容として扱われる
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("a: 50%value");
	assert(result.getValue!string("a") == "50%value");
}

// parse() - コメント・アンカー・タグを組み合わせた総合テスト
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("# doc comment\na: &x !!str hello # trailing\nb: *x\n");
	auto a = result.asMapping["a"];
	assert(a.tagName.get == "!!str");
	assert(a.get!string == "hello");
	assert(a.isTrailingComment(a.getCommentLength() - 1));
	assert(result.getComment(0) == " doc comment");
	assert(result.asMapping["b"].get!string == "hello");
}

// parse() - 同一builderインスタンスを再利用しても、前回のparse()の
// anchorTableが後続のparse()呼び出しに漏れ出さない
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	auto result1 = builder.parse("a: &x 1\nb: *x");
	assert(result1.asMapping["b"].get!int == 1);
	// 1回目で定義した"x"は2回目のparse()には引き継がれず未定義エラーになるはず
	assertThrown!YamlParseException(builder.parse("c: *x"));
	// 3回目は改めて正常にパースできる
	auto result3 = builder.parse("d: 3");
	assert(result3.getValue!int("d") == 3);
}

// putYamlBooleanImpl - rawテキスト優先、rawが無い場合は1.2 Core Schema既定表記
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlBoolean(true);
		val.raw = cast(YamlBuilder.String)"Yes";
		auto app = appender!(char[])();
		builder.putYamlBooleanImpl(app, val);
		assert(app.data == "Yes");
	}
	{
		auto val = YamlValue.YamlBoolean(true);
		auto app = appender!(char[])();
		builder.putYamlBooleanImpl(app, val);
		assert(app.data == "true");
	}
	{
		auto val = YamlValue.YamlBoolean(false);
		auto app = appender!(char[])();
		builder.putYamlBooleanImpl(app, val);
		assert(app.data == "false");
	}
}

// putYamlNullImpl - rawテキスト優先、rawが無い場合は1.2 Core Schema既定表記
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlNull();
		val.raw = cast(YamlBuilder.String)"~";
		auto app = appender!(char[])();
		builder.putYamlNullImpl(app, val);
		assert(app.data == "~");
	}
	{
		auto val = YamlValue.YamlNull();
		auto app = appender!(char[])();
		builder.putYamlNullImpl(app, val);
		assert(app.data == "null");
	}
}

// putYamlIntegerImpl - rawテキスト優先
@safe unittest
{
	YamlBuilder builder;
	auto val = YamlValue.YamlInteger(42);
	val.raw = cast(YamlBuilder.String)"0x2A";
	val.base = IntegerBase.hex; // rawがあればstyle/baseに関わらずrawを優先する
	auto app = appender!(char[])();
	builder.putYamlIntegerImpl(app, val);
	assert(app.data == "0x2A");
}

// putYamlIntegerImpl - rawが無い場合は基数・符号指定に応じて再構成する
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlInteger(42);
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "42");
	}
	{
		auto val = YamlValue.YamlInteger(42);
		val.positiveSign = true;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "+42");
	}
	{
		auto val = YamlValue.YamlInteger(-42);
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "-42");
	}
	{
		auto val = YamlValue.YamlInteger(26);
		val.base = IntegerBase.hex;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "0x1a");
	}
	{
		auto val = YamlValue.YamlInteger(-26);
		val.base = IntegerBase.hex;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "-0x1a");
	}
	{
		auto val = YamlValue.YamlInteger(15);
		val.base = IntegerBase.octal;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "0o17");
	}
	{
		auto val = YamlValue.YamlInteger(5);
		val.base = IntegerBase.binary;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "0b101");
	}
	{
		// long.minは絶対値変換(absULongImpl)がオーバーフローしないことを確認する
		auto val = YamlValue.YamlInteger(long.min);
		val.base = IntegerBase.hex;
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, val);
		assert(app.data == "-0x8000000000000000");
	}
}

// putYamlUIntegerImpl - rawテキスト優先、rawが無い場合は基数・符号指定に応じて再構成する
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlUInteger(ulong.max);
		val.raw = cast(YamlBuilder.String)"18446744073709551615";
		auto app = appender!(char[])();
		builder.putYamlUIntegerImpl(app, val);
		assert(app.data == "18446744073709551615");
	}
	{
		auto val = YamlValue.YamlUInteger(255);
		val.base = IntegerBase.hex;
		auto app = appender!(char[])();
		builder.putYamlUIntegerImpl(app, val);
		assert(app.data == "0xff");
	}
	{
		auto val = YamlValue.YamlUInteger(255);
		val.positiveSign = true;
		auto app = appender!(char[])();
		builder.putYamlUIntegerImpl(app, val);
		assert(app.data == "+255");
	}
}

// putYamlFloatingPointImpl - rawテキスト優先
@safe unittest
{
	YamlBuilder builder;
	auto val = YamlValue.YamlFloatingPoint(1.0);
	val.raw = cast(YamlBuilder.String)"1_000.0";
	auto app = appender!(char[])();
	builder.putYamlFloatingPointImpl(app, val);
	assert(app.data == "1_000.0");
}

// putYamlFloatingPointImpl - 無限大・NaNは1.2 Core Schema表記になる
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlFloatingPoint(double.infinity);
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == ".inf");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(-double.infinity);
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "-.inf");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(double.nan);
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == ".nan");
	}
}

// putYamlFloatingPointImpl - rawが無い場合はフラグに応じて再構成する（有限値・precision無し）
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlFloatingPoint(3.14);
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "3.14");
	}
	{
		// leadingDecimalPoint: 元が\".5\"のように先頭の0を省略していた場合を再現する
		auto val = YamlValue.YamlFloatingPoint(0.5);
		val.leadingDecimalPoint = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == ".5");
	}
	{
		// tailingDecimalPointが未指定（既定false）の場合は\"5.0\"のように0を補う
		auto val = YamlValue.YamlFloatingPoint(5.0);
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "5.0");
	}
	{
		// tailingDecimalPoint: 元が\"5.\"のように末尾の0を省略していた場合を再現する
		auto val = YamlValue.YamlFloatingPoint(5.0);
		val.tailingDecimalPoint = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "5.");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(3.14);
		val.positiveSign = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "+3.14");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(3.14159);
		val.precision = 2;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "3.14");
	}
}

// putYamlFloatingPointImpl - rawが無い場合はフラグに応じて再構成する（指数表記）
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlFloatingPoint(12345.0);
		val.withExponent = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "1.2345e+4");
	}
	{
		// 指数表記でもprecision指定が正しく反映される
		auto val = YamlValue.YamlFloatingPoint(12345.0);
		val.withExponent = true;
		val.precision = 3;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "1.234e+4");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(0.0001234);
		val.withExponent = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "1.234e-4");
	}
	{
		auto val = YamlValue.YamlFloatingPoint(12345.0);
		val.withExponent = true;
		val.positiveSign = true;
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, val);
		assert(app.data == "+1.2345e+4");
	}
}

// putYamlStringImpl - rawが非空であればstyleに関わらず無条件でrawを出力する
@safe unittest
{
	YamlBuilder builder;
	auto val = YamlValue.YamlString(cast(YamlBuilder.String)"ignored");
	val.style = ScalarStyle.doubleQuoted; // raw優先ならこのstyleは無視されるはず
	val.raw = cast(YamlBuilder.String)"RAW_WINS";
	auto app = appender!(char[])();
	builder.putYamlStringImpl(app, val, "  ", "\n", 0);
	assert(app.data == "RAW_WINS");
}

// putYamlStringImpl - プレーンスタイル（rawが無い場合）
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"hello");
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "hello");
	}
	{
		// 改行を含む内容はプレーンスカラーとして安全でないため、値を破壊しないよう
		// ダブルクォートへ自動フォールバックする
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"a\nb");
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "\"a\\nb\"");
	}
	{
		// インジケータ文字(`-`)で始まる内容もダブルクォートへ自動フォールバックする
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"- item");
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "\"- item\"");
	}
	{
		// 空文字列はプレーンスカラーとしては暗黙nullと解釈されてしまうため
		// ダブルクォートへ自動フォールバックする
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"");
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "\"\"");
	}
}

// putYamlStringImpl - シングルクォートスタイル（`'`は2つ重ねてエスケープする）
@safe unittest
{
	YamlBuilder builder;
	{
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"it's");
		val.style = ScalarStyle.singleQuoted;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "'it''s'");
	}
	{
		// シングルクォートでは改行を表現できないため、値を破壊しないよう
		// ダブルクォートへ自動フォールバックする
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"a\nb");
		val.style = ScalarStyle.singleQuoted;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "\"a\\nb\"");
	}
}

// putYamlStringImpl - ダブルクォートスタイル（制御文字・`"`・`\`をエスケープする）
@safe unittest
{
	YamlBuilder builder;
	auto val = YamlValue.YamlString(cast(YamlBuilder.String)"a\"b\\c\td");
	val.style = ScalarStyle.doubleQuoted;
	auto app = appender!(char[])();
	builder.putYamlStringImpl(app, val, "  ", "\n", 0);
	assert(app.data == "\"a\\\"b\\\\c\\td\"");
}

// putYamlStringImpl - literalブロックスカラー（clip/strip/keepの各chomping）
@safe unittest
{
	YamlBuilder builder;
	{
		// clip: 末尾の改行はちょうど1つ保持される
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"line1\nline2\n");
		val.style = ScalarStyle.literal;
		val.chomping = ChompingIndicator.clip;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "|\n  line1\n  line2\n");
	}
	{
		// strip: 値には末尾改行が無いが、出力テキスト上は次要素との区切りとして
		// 物理的な改行が1つ必要になる
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"line1\nline2");
		val.style = ScalarStyle.literal;
		val.chomping = ChompingIndicator.strip;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "|-\n  line1\n  line2\n");
	}
	{
		// keep: 末尾の複数改行がすべて保持される
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"line1\n\n\n");
		val.style = ScalarStyle.literal;
		val.chomping = ChompingIndicator.keep;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "|+\n  line1\n\n\n");
	}
	{
		// 空のブロックスカラー: ヘッダ行のみが出力される
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"");
		val.style = ScalarStyle.literal;
		val.chomping = ChompingIndicator.strip;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 0);
		assert(app.data == "|-\n");
	}
	{
		// indentLevelに応じてネストした深さでインデントされる
		auto val = YamlValue.YamlString(cast(YamlBuilder.String)"line1\n");
		val.style = ScalarStyle.literal;
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, val, "  ", "\n", 1);
		assert(app.data == "|\n    line1\n");
	}
}

// putYamlStringImpl - foldedブロックスカラー
@safe unittest
{
	YamlBuilder builder;
	auto val = YamlValue.YamlString(cast(YamlBuilder.String)"line1\n");
	val.style = ScalarStyle.folded;
	auto app = appender!(char[])();
	builder.putYamlStringImpl(app, val, "  ", "\n", 0);
	assert(app.data == ">\n  line1\n");
}

// 統合テスト - parse()の結果を各put*Implでstringifyすると元のテキストと一致する（rawテキスト優先方式）
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("i: 0x1A\nf: 3.14\nb: yes\nn: ~\ns: hello\n");
	auto m = root.asMapping;
	{
		auto app = appender!(char[])();
		builder.putYamlIntegerImpl(app, m["i"].asInteger);
		assert(app.data == "0x1A");
	}
	{
		auto app = appender!(char[])();
		builder.putYamlFloatingPointImpl(app, m["f"].asFloatingPoint);
		assert(app.data == "3.14");
	}
	{
		auto app = appender!(char[])();
		builder.putYamlBooleanImpl(app, m["b"].asBoolean);
		assert(app.data == "yes");
	}
	{
		auto app = appender!(char[])();
		builder.putYamlNullImpl(app, m["n"].asNull);
		assert(app.data == "~");
	}
	{
		auto app = appender!(char[])();
		builder.putYamlStringImpl(app, m["s"].asString, "  ", "\n", 0);
		assert(app.data == "hello");
	}
}

// putYamlKeyImpl - plain/シングルクォート/ダブルクォートの各スタイル
@safe unittest
{
	YamlBuilder builder;
	{
		auto key = YamlValue.YamlKey(cast(YamlBuilder.String)"name");
		auto app = appender!(char[])();
		builder.putYamlKeyImpl(app, key);
		assert(app.data == "name");
	}
	{
		// 改行を含む安全でない内容はダブルクォートへフォールバックする
		auto key = YamlValue.YamlKey(cast(YamlBuilder.String)"a\nb");
		auto app = appender!(char[])();
		builder.putYamlKeyImpl(app, key);
		assert(app.data == "\"a\\nb\"");
	}
	{
		auto key = YamlValue.YamlKey(cast(YamlBuilder.String)"it's");
		key.style = ScalarStyle.singleQuoted;
		auto app = appender!(char[])();
		builder.putYamlKeyImpl(app, key);
		assert(app.data == "'it''s'");
	}
	{
		auto key = YamlValue.YamlKey(cast(YamlBuilder.String)"a b");
		key.style = ScalarStyle.doubleQuoted;
		auto app = appender!(char[])();
		builder.putYamlKeyImpl(app, key);
		assert(app.data == "\"a b\"");
	}
}

// putYamlFlowNodeImpl - エイリアスノードは`*name`のみを出力する
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("[&anchor 1, *anchor]");
	auto s = root.asSequence;
	auto app = appender!(char[])();
	builder.putYamlFlowNodeImpl(app, s[1], "  ", "\n", 0);
	assert(app.data == "*anchor");
}

// putYamlFlowSequenceImpl - 空シーケンス
@safe unittest
{
	YamlBuilder builder;
	YamlValue.YamlSequence seq;
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, seq, "  ", "\n", 0);
	assert(app.data == "[]");
}

// 注: 以下はYamlValue(val, builder)コンストラクタ(@system)を使うため@system unittestとする

// putYamlFlowSequenceImpl - singleLine(ケツカンマ有無)
@system unittest
{
	YamlBuilder builder;
	{
		auto v = YamlValue([1L, 2L, 3L], builder);
		v.asSequence.singleLine = true;
		auto app = appender!(char[])();
		builder.putYamlFlowSequenceImpl(app, v.asSequence, "  ", "\n", 0);
		assert(app.data == "[1, 2, 3]");
	}
	{
		auto v = YamlValue([1L, 2L, 3L], builder);
		v.asSequence.singleLine = true;
		v.asSequence.trailingComma = true;
		auto app = appender!(char[])();
		builder.putYamlFlowSequenceImpl(app, v.asSequence, "  ", "\n", 0);
		assert(app.data == "[1, 2, 3,]");
	}
}

// putYamlFlowSequenceImpl - 複数行(singleLine=false)
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue([1L, 2L], builder);
	v.asSequence.singleLine = false;
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, v.asSequence, "  ", "\n", 0);
	assert(app.data == "[\n  1,\n  2\n]");
}

// putYamlFlowSequenceImpl - 複数行+ケツカンマ
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue([1L, 2L], builder);
	v.asSequence.singleLine = false;
	v.asSequence.trailingComma = true;
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, v.asSequence, "  ", "\n", 0);
	assert(app.data == "[\n  1,\n  2,\n]");
}

// putYamlFlowSequenceImpl - ネストしたflowシーケンス
@system unittest
{
	YamlBuilder builder;
	auto innerVal = YamlValue([2L, 3L], builder);
	innerVal.asSequence.singleLine = true;
	auto outerVal = YamlValue(1L, builder);
	auto ary = builder.allocAry!YamlValue;
	ary ~= outerVal;
	ary ~= innerVal;
	auto seq = YamlValue.YamlSequence(ary);
	seq.singleLine = true;
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, seq, "  ", "\n", 0);
	assert(app.data == "[1, [2, 3]]");
}

// putYamlFlowMappingImpl - 空マッピング
@safe unittest
{
	YamlBuilder builder;
	YamlValue.YamlMapping mapping;
	auto app = appender!(char[])();
	builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "{}");
}

// 注: 以下はDictionary!(YamlKey, YamlValue)を明示的な順序で構築するため、
// キーの反復順序(挿入順)が保証された状態でテストできる
// (D連想配列リテラルはハッシュ順のため、順序に依存するテストには使わない)

// putYamlFlowMappingImpl - singleLine(ケツカンマ有無)
@system unittest
{
	YamlBuilder builder;
	{
		auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
		dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
		dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), YamlValue(2L, builder));
		auto mapping = YamlValue.YamlMapping(dic);
		mapping.singleLine = true;
		auto app = appender!(char[])();
		builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
		assert(app.data == "{a: 1, b: 2}");
	}
	{
		auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
		dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
		dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), YamlValue(2L, builder));
		auto mapping = YamlValue.YamlMapping(dic);
		mapping.singleLine = true;
		mapping.trailingComma = true;
		auto app = appender!(char[])();
		builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
		assert(app.data == "{a: 1, b: 2,}");
	}
}

// putYamlFlowMappingImpl - 複数行(singleLine=false)
@system unittest
{
	YamlBuilder builder;
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), YamlValue(2L, builder));
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.singleLine = false;
	auto app = appender!(char[])();
	builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "{\n  a: 1,\n  b: 2\n}");
}

// putYamlFlowMappingImpl - ネストしたflowシーケンスを値に持つ
@system unittest
{
	YamlBuilder builder;
	auto innerVal = YamlValue([1L, 2L], builder);
	innerVal.asSequence.singleLine = true;
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), innerVal);
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.singleLine = true;
	auto app = appender!(char[])();
	builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "{a: [1, 2]}");
}

// putYamlFlowMappingImpl - Type.undefinedの値を持つエントリは出力をスキップする
@system unittest
{
	YamlBuilder builder;
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
	YamlValue undef;
	assert(undef.type == YamlBuilder.YamlType.undefined);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), undef);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"c"), YamlValue(3L, builder));
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.singleLine = true;
	auto app = appender!(char[])();
	builder.putYamlFlowMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "{a: 1, c: 3}");
}

// 統合テスト - parse()したflowシーケンスをstringifyすると同じテキストが得られ、
// その結果を再度parse()しても同じ値が得られる(ラウンドトリップ)
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("[1, 2, 3,]");
	assert(root.asSequence.singleLine == true);
	assert(root.asSequence.trailingComma == true);
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, root.asSequence, "  ", "\n", 0);
	assert(app.data == "[1, 2, 3,]");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getElement!int(0) == 1);
	assert(reparsed.getElement!int(1) == 2);
	assert(reparsed.getElement!int(2) == 3);
}

// 統合テスト - 複数行にまたがるflowシーケンス(singleLine=false)のラウンドトリップ
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("[\n  1,\n  2,\n  3\n]");
	assert(root.asSequence.singleLine == false);
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, root.asSequence, "  ", "\n", 0);
	assert(app.data == "[\n  1,\n  2,\n  3\n]");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getElement!int(0) == 1);
	assert(reparsed.getElement!int(1) == 2);
	assert(reparsed.getElement!int(2) == 3);
}

// 統合テスト - parse()したflowマッピングをstringifyすると同じテキストが得られる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("{a: 1, b: 2}");
	assert(root.asMapping.singleLine == true);
	auto app = appender!(char[])();
	builder.putYamlFlowMappingImpl(app, root.asMapping, "  ", "\n", 0);
	assert(app.data == "{a: 1, b: 2}");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getValue!int("a") == 1);
	assert(reparsed.getValue!int("b") == 2);
}

// 統合テスト - ネストしたflowコレクション(シーケンス内マッピング)のラウンドトリップ
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("[{a: 1}, {b: 2}]");
	auto app = appender!(char[])();
	builder.putYamlFlowSequenceImpl(app, root.asSequence, "  ", "\n", 0);
	assert(app.data == "[{a: 1}, {b: 2}]");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.asSequence[0].getValue!int("a") == 1);
	assert(reparsed.asSequence[1].getValue!int("b") == 2);
}

// putYamlBlockSequenceImpl - フラットなシーケンス
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue([1L, 2L, 3L], builder);
	v.asSequence.style = CollectionStyle.block;
	auto app = appender!(char[])();
	builder.putYamlBlockSequenceImpl(app, v.asSequence, "  ", "\n", 0);
	assert(app.data == "- 1\n- 2\n- 3\n");
}

// putYamlBlockMappingImpl - フラットなマッピング
@system unittest
{
	YamlBuilder builder;
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), YamlValue(2L, builder));
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "a: 1\nb: 2\n");
}

// putYamlBlockMappingImpl - ネストしたblockマッピングを値に持つ場合、
// 改行して`indentLevel + 1`でインデントする
@system unittest
{
	YamlBuilder builder;
	auto innerDic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	innerDic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"x"), YamlValue(1L, builder));
	innerDic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"y"), YamlValue(2L, builder));
	auto innerMapping = YamlValue.YamlMapping(innerDic);
	auto inner = YamlValue(innerMapping, builder);
	inner.asMapping.style = CollectionStyle.block;
	
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), inner);
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "a:\n  x: 1\n  y: 2\n");
}

// putYamlBlockMappingImpl - ネストしたblockシーケンスを値に持つ場合、
// 改行して`indentLevel + 1`でインデントする(YAML仕様上は同一インデントも
// 許容されるが、出力は常に一段深いインデントに統一する簡略化方針)
@system unittest
{
	YamlBuilder builder;
	auto innerSeq = YamlValue([1L, 2L], builder);
	innerSeq.asSequence.style = CollectionStyle.block;
	
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"items"), innerSeq);
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "items:\n  - 1\n  - 2\n");
}

// putYamlBlockSequenceImpl - 項目がblockマッピングの場合、`-`の次の行から
// 一段深いインデントで各キーを出力する(先頭キーをダッシュに続けてインライン
// 出力する慣用スタイルは意図的に採用しない)
@system unittest
{
	YamlBuilder builder;
	auto innerDic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	innerDic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"name"), YamlValue("Alice", builder));
	innerDic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"age"), YamlValue(30L, builder));
	auto innerMapping = YamlValue.YamlMapping(innerDic);
	auto inner = YamlValue(innerMapping, builder);
	inner.asMapping.style = CollectionStyle.block;
	
	auto ary = builder.allocAry!YamlValue;
	ary ~= inner;
	auto seq = YamlValue.YamlSequence(ary);
	seq.style = CollectionStyle.block;
	
	auto app = appender!(char[])();
	builder.putYamlBlockSequenceImpl(app, seq, "  ", "\n", 0);
	assert(app.data == "-\n  name: Alice\n  age: 30\n");
}

// putYamlBlockMappingImpl - flowスタイルのコレクションを値に持つ場合は
// プレフィックスと同一行にインライン出力する
@system unittest
{
	YamlBuilder builder;
	auto innerSeq = YamlValue([1L, 2L, 3L], builder);
	innerSeq.asSequence.style = CollectionStyle.flow;
	innerSeq.asSequence.singleLine = true;
	
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"items"), innerSeq);
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "items: [1, 2, 3]\n");
}

// putYamlBlockMappingImpl - 空のblockスタイルコレクションはflowの`[]`/`{}`で
// インライン出力する(block記法では空コレクションを表現できないため)
@system unittest
{
	YamlBuilder builder;
	YamlValue.YamlSequence emptySeq;
	emptySeq.style = CollectionStyle.block;
	auto emptyVal = YamlValue(emptySeq, builder);
	
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"items"), emptyVal);
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "items: []\n");
}

// putYamlBlockMappingImpl - Type.undefinedの値を持つエントリは出力をスキップする
@system unittest
{
	YamlBuilder builder;
	auto dic = builder.allocDic!(YamlBuilder.YamlKey, YamlValue);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), YamlValue(1L, builder));
	YamlValue undef;
	assert(undef.type == YamlBuilder.YamlType.undefined);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), undef);
	dic.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"c"), YamlValue(3L, builder));
	auto mapping = YamlValue.YamlMapping(dic);
	mapping.style = CollectionStyle.block;
	auto app = appender!(char[])();
	builder.putYamlBlockMappingImpl(app, mapping, "  ", "\n", 0);
	assert(app.data == "a: 1\nc: 3\n");
}

// putYamlBlockNodeImpl - トップレベルディスパッチャ(スカラーはそのままインライン出力)
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("hello");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "hello");
}

// putYamlBlockNodeImpl - トップレベルがblockマッピングの場合、先頭に
// 余分な改行を挟まずそのままキーの列挙から始まる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\nb: 2\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: 1\nb: 2\n");
}

// 統合テスト - parse()したネスト構造(マッピングの値がマッピング)を
// putYamlBlockNodeImplでstringifyすると同じ木構造にラウンドトリップできる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\nb:\n  c: 2\n  d: 3\ne: 4\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: 1\nb:\n  c: 2\n  d: 3\ne: 4\n");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getValue!int("a") == 1);
	assert(reparsed.getValue!int("e") == 4);
	assert(reparsed.asMapping["b"].getValue!int("c") == 2);
	assert(reparsed.asMapping["b"].getValue!int("d") == 3);
}

// 統合テスト - parse()したネスト構造(シーケンスの値としてのマッピングの
// リスト)をputYamlBlockNodeImplでstringifyしてもラウンドトリップできる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("- name: Alice\n  age: 30\n- name: Bob\n  age: 25\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.asSequence[0].getValue!string("name") == "Alice");
	assert(reparsed.asSequence[0].getValue!int("age") == 30);
	assert(reparsed.asSequence[1].getValue!string("name") == "Bob");
	assert(reparsed.asSequence[1].getValue!int("age") == 25);
}

// 統合テスト - blockとflowが混在するマッピング(値がflowシーケンス)の
// ラウンドトリップ
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("name: test\nvalues: [1, 2, 3]\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "name: test\nvalues: [1, 2, 3]\n");
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getValue!string("name") == "test");
	assert(reparsed.asMapping["values"].getElement!int(0) == 1);
	assert(reparsed.asMapping["values"].getElement!int(2) == 3);
}

// putYamlCommentLinesImpl - 複数行のleadingコメントをそれぞれ独立した行として出力する
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(1L, builder);
	v.addLineComment(" first");
	v.addLineComment(" second");
	auto app = appender!(char[])();
	builder.putYamlCommentLinesImpl(app, v._comments, "  ", "\n", 1);
	assert(app.data == "  # first\n  # second\n");
}

// putYamlTrailingCommentImpl - 末尾がTrailingCommentの場合のみ出力し、
// 空白1つ+`#`+本文の形で出力する
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(1L, builder);
	v.addLineComment(" leading");
	v.addTrailingComment(" trailing");
	auto app = appender!(char[])();
	builder.putYamlTrailingCommentImpl(app, v._comments);
	assert(app.data == " # trailing");
}

// putYamlTrailingCommentImpl - leadingコメントしか無い場合は何も出力しない
// (TrailingCommentは配列の最後尾にしか現れないため)
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(2L, builder);
	v.addLineComment(" leading only");
	auto app = appender!(char[])();
	builder.putYamlTrailingCommentImpl(app, v._comments);
	assert(app.data.length == 0);
}

// 統合テスト - blockマッピングでキー行の前にあるコメントは、次のエントリの
// 値のleadingコメントとしてラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\n# comment about b\nb: 2\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: 1\n# comment about b\nb: 2\n");
}

// 統合テスト - スカラー値と同一行の末尾コメントがラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1 # note\nb: 2\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: 1 # note\nb: 2\n");
}

// 統合テスト - blockシーケンス末尾のぶら下がりコメントがラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("- 1\n- 2\n# trailing note\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "- 1\n- 2\n# trailing note\n");
}

// 統合テスト - blockマッピング末尾のぶら下がりコメントがラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\nb: 2\n# end note\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: 1\nb: 2\n# end note\n");
}

// 統合テスト - ネストしたblockマッピング自身のleadingコメント(`key:`の
// 次の行、ネスト本体の先頭)がラウンドトリップする。このコメントは
// パーサ上「ネストした値自身」に付与されるため、`key:`行より前ではなく
// ネスト本体の直前(indentLevel+1)に出力する必要がある(putYamlBlockChildImpl
// 参照)
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a:\n  # nested comment\n  x: 1\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a:\n  # nested comment\n  x: 1\n");
}

// 統合テスト - シーケンス項目自身がネストしたblockマッピングの場合も、
// 同様に`-`の次の行・ネスト本体の先頭にleadingコメントが出力される
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("-\n  # note\n  y: 2\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "-\n  # note\n  y: 2\n");
}

// 統合テスト - マッピング値であるblockシーケンス自身のleadingコメントも
// 同じ方針でラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("items:\n  # c\n  - 1\n  - 2\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "items:\n  # c\n  - 1\n  - 2\n");
}

// 統合テスト - flowコレクション(複数行)内で要素の前に単独行として
// 置かれたコメントがラウンドトリップする。flow文脈のコメントは常に
// 「次のトークンへのleadingコメント」として扱われる(要素の直後・同一行の
// `# comment`であっても、パーサはそれを次要素へのleadingコメントとして
// 記録する。既知の仕様であり、stringify側はこの構造をそのまま
// 出力するのみで、同一行末コメントとしての区別は行わない)
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: [\n  1,\n  # note\n  2,\n]\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: [\n  1,\n  # note\n  2,\n]\n");
}

// 統合テスト - flowシーケンス末尾(閉じ角括弧の前)のぶら下がりコメントが
// ラウンドトリップする
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: [\n  1,\n  2,\n  # end\n]\n");
	auto app = appender!(char[])();
	builder.putYamlBlockNodeImpl(app, root, "  ", "\n", 0);
	assert(app.data == "a: [\n  1,\n  2,\n  # end\n]\n");
}

// toPrettyString() - 既定オプションでのラウンドトリップ（block構造の基本形）
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\nb:\n  x: 2\n  y: 3\nc:\n  - 1\n  - 2\n");
	auto app = appender!(char[])();
	builder.toPrettyString(app, root);
	assert(app.data == "a: 1\nb:\n  x: 2\n  y: 3\nc:\n  - 1\n  - 2\n");
}

// toPrettyString() - ルート自身のleadingコメント（ドキュメント先頭の
// コメント）がラウンドトリップする。`putYamlBlockNodeImpl`単体では
// ルート自身のコメントを出力できない（子のコメントしか扱わないため）ため、
// `toPrettyString`が最上位でこれを補う必要があることを確認する
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("# top level comment\na: 1\nb: 2\n");
	auto app = appender!(char[])();
	builder.toPrettyString(app, root);
	assert(app.data == "# top level comment\na: 1\nb: 2\n");
}

// toPrettyString() - ルートがスカラーの場合のleading/trailingコメント
// （改行を追加しないことも合わせて確認: 元の入力に末尾改行が無ければ
// 出力にも付与しない）
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("# about x\n1 # trailing note");
	auto app = appender!(char[])();
	builder.toPrettyString(app, root);
	assert(app.data == "# about x\n1 # trailing note");
}

// toPrettyString() - YamlPrettyPrintOptions.indentでインデント幅を
// カスタマイズできる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a:\n  x: 1\n  y: 2\n");
	auto app = appender!(char[])();
	YamlOptions opt;
	opt.indent = "    ";
	builder.toPrettyString(app, root, opt);
	assert(app.data == "a:\n    x: 1\n    y: 2\n");
}

// toPrettyString() - YamlPrettyPrintOptions.newlineで改行コードを
// カスタマイズできる(CRLF)
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: 1\nb: 2\n");
	auto app = appender!(char[])();
	YamlOptions opt;
	opt.newline = "\r\n";
	builder.toPrettyString(app, root, opt);
	assert(app.data == "a: 1\r\nb: 2\r\n");
}

// toPrettyString() - YamlPrettyPrintOptions.escapeNonAsciiが`true`の
// 場合、rawを持たないダブルクォート文字列のASCII範囲外文字が`\uXXXX`で
// エスケープされる(rawを持つ値はraw優先方針により影響を受けない
// ため、ここでは低レベルAPIで直接構築した値を使う)
@system unittest
{
	YamlBuilder builder;
	auto v = YamlValue(cast(string)"caf\u00e9", builder);
	v.asString.style = ScalarStyle.doubleQuoted;
	
	auto app1 = appender!(char[])();
	YamlOptions opt1;
	opt1.escapeNonAscii = true;
	builder.toPrettyString(app1, v, opt1);
	assert(app1.data == "\"caf\\u00E9\"");
	
	auto app2 = appender!(char[])();
	YamlOptions opt2;
	opt2.escapeNonAscii = false;
	builder.toPrettyString(app2, v, opt2);
	assert(app2.data == "\"caf\u00e9\"");
}

// toPrettyString() - 複数のコメント種別(leading/trailing/dangling)と
// block/flowが混在する、より現実的な入力全体のラウンドトリップ
@safe unittest
{
	YamlBuilder builder;
	auto src = "name: test\nb:\n  x: 1 # x comment\n  y: [1, 2, 3]\n" ~
		"items:\n  - a\n  - b\n# footer\n";
	auto root = builder.parse(src);
	auto app = appender!(char[])();
	builder.toPrettyString(app, root);
	assert(app.data == src);
	
	YamlBuilder builder2;
	auto reparsed = builder2.parse(app.data);
	assert(reparsed.getValue!string("name") == "test");
	assert(reparsed.asMapping["b"].getValue!int("x") == 1);
	assert(reparsed.asMapping["b"].asMapping["y"].getElement!int(1) == 2);
	assert(reparsed.asMapping["items"].getElement!string(0) == "a");
}

// make() - 基本的なスカラー型の構築(opAssignの各分岐をmake()経由で確認。
// make()自体は@trustedだが呼び出し側は@safeのまま使える)
@safe unittest
{
	YamlBuilder builder;
	
	auto vs = builder.make("hello");
	assert(vs.type == YamlBuilder.YamlType.string);
	assert(vs.get!string == "hello");
	
	auto vi = builder.make(42);
	assert(vi.type == YamlBuilder.YamlType.integer);
	assert(vi.get!int == 42);
	
	auto vu = builder.make(42U);
	assert(vu.type == YamlBuilder.YamlType.uinteger);
	assert(vu.get!uint == 42);
	
	auto vf = builder.make(3.14);
	assert(vf.type == YamlBuilder.YamlType.floating);
	
	auto vb = builder.make(true);
	assert(vb.type == YamlBuilder.YamlType.boolean);
	assert(vb.get!bool == true);
	
	auto vn = builder.make(null);
	assert(vn.type == YamlBuilder.YamlType.nullfied);
}

// make() - 配列・連想配列の構築(要素としてmake()自身の結果をネストできる)
@safe unittest
{
	YamlBuilder builder;
	
	auto va = builder.make([builder.make(1), builder.make(2), builder.make(3)]);
	assert(va.type == YamlBuilder.YamlType.sequence);
	assert(va.getElement!int(0) == 1);
	assert(va.getElement!int(2) == 3);
	
	auto vm = builder.make(["a": builder.make(1), "b": builder.make(2)]);
	assert(vm.type == YamlBuilder.YamlType.mapping);
	assert(vm.getValue!int("a") == 1);
	assert(vm.getValue!int("b") == 2);
}

// make() - Yaml*構造体そのものを渡した場合、rawを持たないフラグ
// (positiveSign/base等)もそのまま保持される
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.make(YamlValue.YamlInteger(42, true, IntegerBase.hex));
	assert(v.type == YamlBuilder.YamlType.integer);
	assert(v.asInteger.value == 42);
	assert(v.asInteger.positiveSign == true);
	assert(v.asInteger.base == IntegerBase.hex);
}

// undefinedValue() - Type.undefinedを返す(デフォルト構築のYamlValueと同じtype)
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.undefinedValue();
	assert(v.type == YamlBuilder.YamlType.undefined);
	assert(v.type == YamlValue.init.type);
}

// emptyArray()/emptyObject() - 空のblockスタイルコレクションを返す
@safe unittest
{
	YamlBuilder builder;
	
	auto ea = builder.emptyArray();
	assert(ea.type == YamlBuilder.YamlType.sequence);
	assert(ea.asSequence.value.length == 0);
	assert(ea.asSequence.style == CollectionStyle.block);
	
	auto eo = builder.emptyObject();
	assert(eo.type == YamlBuilder.YamlType.mapping);
	assert(eo.asMapping.value.length == 0);
	assert(eo.asMapping.style == CollectionStyle.block);
}

// emptyArray()/emptyObject() - 要素数0のためtoPrettyString()では常に
// flow形式("[]"/"{}")で出力される(block記法では空コレクションを表現できない
// 仕様上の制約のため。isBlockNestedCollectionImplの判定を参照)
@safe unittest
{
	YamlBuilder builder;
	auto ea = builder.emptyArray();
	auto eo = builder.emptyObject();
	
	auto app1 = appender!(char[])();
	builder.toPrettyString(app1, ea);
	assert(app1.data == "[]");
	
	auto app2 = appender!(char[])();
	builder.toPrettyString(app2, eo);
	assert(app2.data == "{}");
}

// emptyObject()にappend()で組み立てたマッピングは、undefinedValue()を
// 値に持つエントリだけtoPrettyString()でスキップされる(連想配列リテラルは
// 走査順序が不定なため使わず、Dictionary.append()で順序を明示的に制御する)
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.emptyObject();
	v.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), builder.make(1));
	v.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), builder.undefinedValue());
	v.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"c"), builder.make(3));
	
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == "a: 1\nc: 3\n");
}

// deepCopy() - make()で構築したシーケンスの複製は独立したポインタを持ち、
// 複製先を変更しても複製元に影響しない
@safe unittest
{
	YamlBuilder builder;
	auto src = builder.make([builder.make(1), builder.make(2)]);
	auto dst = builder.deepCopy(src);
	assert(&dst.asSequence.value[0] !is &src.asSequence.value[0]);
	assert(dst.getElement!int(0) == 1);
	
	dst.asSequence.value[0] = builder.make(100);
	assert(dst.getElement!int(0) == 100);
	assert(src.getElement!int(0) == 1);
}

// deepCopy() - make()で構築したマッピングの複製も同様に独立している
@safe unittest
{
	YamlBuilder builder;
	auto src = builder.make(["a": builder.make(1)]);
	auto dst = builder.deepCopy(src);
	assert(&dst.asMapping.value[0] !is &src.asMapping.value[0]);
	assert(dst.getValue!int("a") == 1);
}

// deepCopy() - スカラー値のraw・アンカー・タグも複製される
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: &x !!int 42\n");
	auto orig = root.asMapping["a"];
	assert(orig.anchorName.get == "x");
	assert(orig.tagName.get == "!!int");
	assert(orig.asInteger.raw[] == "42");
	
	auto copied = builder.deepCopy(orig);
	assert(copied.get!int == 42);
	assert(copied.anchorName.get == "x");
	assert(copied.tagName.get == "!!int");
	assert(copied.asInteger.raw[] == "42");
}

// deepCopy() - undefinedValue()を複製してもtypeがundefinedのまま保たれ、
// `_builder`が正しく設定される(以前は未定義値分岐で`YamlValue.init`を直書き
// していたため`_builder`が未設定のままだったバグの回帰テスト)
@safe unittest
{
	YamlBuilder builder;
	auto src = builder.undefinedValue();
	auto dst = builder.deepCopy(src);
	assert(dst.type == YamlBuilder.YamlType.undefined);
	assert(dst._builder !is null);
}

// update() - 文字列を同じ型のまま更新すると、rawはクリアされるが
// style等の他のフォーマット情報は保持される(単純なクォート済み文字列は
// パーサーがrawを設定しない(value+styleのみで再現可能なため)ため、
// ここではmake()でrawを持つYamlStringを直接構築して検証する)
@safe unittest
{
	YamlBuilder builder;
	auto dst = builder.make(YamlValue.YamlString(cast(YamlBuilder.String)"hello",
		ScalarStyle.doubleQuoted, cast(YamlBuilder.String)"\"hello\""));
	assert(dst.asString.raw[] == "\"hello\"");
	assert(dst.asString.style == ScalarStyle.doubleQuoted);
	
	builder.update(dst, "world");
	
	assert(dst.get!string == "world");
	assert(dst.asString.raw.length == 0);
	assert(dst.asString.style == ScalarStyle.doubleQuoted);
}

// update() - 整数/符号なし整数/浮動小数点/真偽値/nullを同じ型のまま
// 更新すると、それぞれrawがクリアされる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("i: 0x2A\nu: 10\nf: 1.5\nb: yes\nn: ~\n");
	assert(root.asMapping["i"].asInteger.raw.length > 0);
	
	builder.update(root.asMapping["i"], 100);
	assert(root.asMapping["i"].get!int == 100);
	assert(root.asMapping["i"].asInteger.raw.length == 0);
	
	builder.update(root.asMapping["u"], 200U);
	assert(root.asMapping["u"].get!uint == 200);
	assert(root.asMapping["u"].asUInteger.raw.length == 0);
	
	builder.update(root.asMapping["f"], 2.5);
	assert(root.asMapping["f"].get!double == 2.5);
	assert(root.asMapping["f"].asFloatingPoint.raw.length == 0);
	
	builder.update(root.asMapping["b"], false);
	assert(root.asMapping["b"].get!bool == false);
	assert(root.asMapping["b"].asBoolean.raw.length == 0);
	
	builder.update(root.asMapping["n"], null);
	assert(root.asMapping["n"].type == YamlBuilder.YamlType.nullfied);
	assert(root.asMapping["n"].asNull.raw.length == 0);
}

// update() - wstring等isSomeStringな型もstringへ変換されて更新される
@safe unittest
{
	YamlBuilder builder;
	auto dst = builder.make("x");
	wstring w = "wide"w;
	builder.update(dst, w);
	assert(dst.get!string == "wide");
}

// update() - 値の型が異なる場合は再構築されるが、アンカー・コメントは
// dst側のものが保持される
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("s: &anc 42 # note\n");
	assert(root.asMapping["s"].type == YamlBuilder.YamlType.integer);
	assert(root.asMapping["s"].anchorName.get == "anc");
	assert(root.asMapping["s"].getCommentLength == 1);
	
	builder.update(root.asMapping["s"], "now a string");
	
	assert(root.asMapping["s"].type == YamlBuilder.YamlType.string);
	assert(root.asMapping["s"].get!string == "now a string");
	assert(root.asMapping["s"].anchorName.get == "anc");
	assert(root.asMapping["s"].getCommentLength == 1);
}

// update() - 配列は伸長・切り詰めの両方に対応し、既存要素は
// (型が一致する限り)再帰的にin-place更新される
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.make([builder.make(1), builder.make(2), builder.make(3)]);
	
	builder.update(root, [10, 20, 30, 40]);
	assert(root.asSequence.value.length == 4);
	assert(root.getElement!int(0) == 10);
	assert(root.getElement!int(3) == 40);
	
	builder.update(root, [1, 2]);
	assert(root.asSequence.value.length == 2);
	assert(root.getElement!int(0) == 1);
	assert(root.getElement!int(1) == 2);
}

// update() - 連想配列は`src`のキー集合に同期する: 既存キーは更新、
// 新規キーは追加、`src`に存在しない既存キーは削除される
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.emptyObject();
	v.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"a"), builder.make(1));
	v.asMapping.value.append(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b"), builder.make(2));
	
	builder.update(v, ["a": 100, "c": 3]);
	
	assert(v.asMapping.value.length == 2);
	assert(v.getValue!int("a") == 100);
	assert(v.getValue!int("c") == 3);
	assert(v.asMapping.value.opIn(YamlBuilder.YamlKey(cast(YamlBuilder.String)"b")) is null);
}

// update() - srcにYamlValue(シーケンス)を直接渡した場合も再帰的に
// 更新され、複製されたsrc側とは独立している(deepCopy相当の独立性を持つ)
@safe unittest
{
	YamlBuilder builder;
	auto dst = builder.make([builder.make(1), builder.make(2)]);
	auto srcVal = builder.make([builder.make(10), builder.make(20), builder.make(30)]);
	
	builder.update(dst, srcVal);
	
	assert(dst.asSequence.value.length == 3);
	assert(dst.getElement!int(0) == 10);
	assert(dst.getElement!int(2) == 30);
	
	dst.asSequence.value[0] = builder.make(999);
	assert(dst.getElement!int(0) == 999);
	assert(srcVal.getElement!int(0) == 10);
}

// update() - srcにYamlValue(マッピング)を直接渡した場合も
// キー集合の同期を含めて再帰的に更新される
@safe unittest
{
	YamlBuilder builder;
	auto dst = builder.make(["a": builder.make(1)]);
	auto srcVal = builder.make(["a": builder.make(100), "b": builder.make(2)]);
	
	builder.update(dst, srcVal);
	
	assert(dst.asMapping.value.length == 2);
	assert(dst.getValue!int("a") == 100);
	assert(dst.getValue!int("b") == 2);
}

// update() - dstがYamlAlias(`*name`)の場合はエイリアスを解除して
// 具体値に置き換える。アンカー定義側のノードは変化しない
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("a: &x 1\nb: *x\n");
	assert(root.asMapping["b"].type == YamlBuilder.YamlType.alias_);
	
	builder.update(root.asMapping["b"], "resolved now");
	
	assert(root.asMapping["b"].type == YamlBuilder.YamlType.string);
	assert(root.asMapping["b"].get!string == "resolved now");
	assert(root.asMapping["a"].get!int == 1);
}

// update() - dstが元々スカラーでも、srcが配列であれば型が
// 再構築されシーケンスになる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("v: 1\n");
	assert(root.asMapping["v"].type == YamlBuilder.YamlType.integer);
	
	builder.update(root.asMapping["v"], [1, 2, 3]);
	
	assert(root.asMapping["v"].type == YamlBuilder.YamlType.sequence);
	assert(root.asMapping["v"].getElement!int(1) == 2);
}

// update() - 集約型(struct)への対応は現時点では未実装であり、
// コンパイルエラーになることを保証する回帰テスト
@safe unittest
{
	struct Dummy { int x; }
	YamlBuilder builder;
	auto dst = builder.make(1);
	assert(!__traits(compiles, builder.update(dst, Dummy(1))));
}

// update() - parse()結果に対する更新後もtoPrettyString()で
// コメント等のフォーマットを保持したままラウンドトリップできる
@safe unittest
{
	YamlBuilder builder;
	auto root = builder.parse("name: Alice # who\nage: 30\n");
	
	builder.update(root.asMapping["age"], 31);
	
	auto app = appender!(char[])();
	builder.toPrettyString(app, root);
	assert(app.data == "name: Alice # who\nage: 31\n");
}

// ============================================================================
// Serializer のユニットテスト
// ============================================================================

// 単純な構造体のシリアライズ(公開メンバー変数→マッピング)
@safe unittest
{
	struct Data
	{
		int x;
		string y;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1, "hello"));
	assert(v.type == YamlBuilder.YamlType.mapping);
	assert(v.getValue!int("x") == 1);
	assert(v.getValue!string("y") == "hello");
}

// @ignore属性が付与されたメンバーはシリアライズされない
@safe unittest
{
	struct Data
	{
		int x;
		@ignore int y;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1, 2));
	assert(v.asMapping.value.length == 1);
	assert(v.getValue!int("x") == 1);
}

// @ignoreIf属性が付与されたメンバーは条件を満たす場合シリアライズされない
@safe unittest
{
	struct Data
	{
		@ignoreIf!((int a) => a == 0)
		int x;
	}
	YamlBuilder builder;
	auto v1 = builder.serialize(Data(0));
	assert(v1.asMapping.value.length == 0);
	auto v2 = builder.serialize(Data(5));
	assert(v2.asMapping.value.length == 1);
	assert(v2.getValue!int("x") == 5);
}

// @name属性でキー名を変更できる
@safe unittest
{
	struct Data
	{
		@name("renamed") int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(3));
	assert(v.getValue!int("renamed") == 3);
	assert(v.getValue!int("x", -1) == -1);
}

// @value属性でメンバー値の代わりに固定値を使用する
@safe unittest
{
	struct Data
	{
		@value!100 int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	assert(v.getValue!int("x") == 100);
}

// comment属性でコメントを出力に反映する
@safe unittest
{
	struct Data
	{
		@comment("this is x") int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	assert(v.asMapping["x"].getCommentLength == 1);
	assert(v.asMapping["x"].getComment(0) == "this is x");
}

// scalarStyle属性で文字列出力スタイルを指定できる
@safe unittest
{
	struct Data
	{
		@scalarStyle(ScalarStyle.singleQuoted) string s;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data("hello"));
	assert(v.asMapping["s"].asString.style == ScalarStyle.singleQuoted);
}

// integralFormat属性で整数の基数・符号を指定できる
@safe unittest
{
	struct Data
	{
		@integralFormat(true, IntegerBase.hex) int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(255));
	assert(v.asMapping["x"].asInteger.base == IntegerBase.hex);
	assert(v.asMapping["x"].asInteger.positiveSign);
}

// floatingPointFormat属性で浮動小数点の出力形式を指定できる
@safe unittest
{
	struct Data
	{
		@floatingPointFormat(true, true, true, true, 3) double x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1.5));
	assert(v.asMapping["x"].asFloatingPoint.leadingDecimalPoint);
	assert(v.asMapping["x"].asFloatingPoint.tailingDecimalPoint);
	assert(v.asMapping["x"].asFloatingPoint.positiveSign);
	assert(v.asMapping["x"].asFloatingPoint.withExponent);
	assert(v.asMapping["x"].asFloatingPoint.precision == 3);
}

// arrayFormat属性でシーケンスのflow/ケツカンマ/1行出力を指定できる
@safe unittest
{
	struct Data
	{
		@arrayFormat(CollectionStyle.flow, true, true) int[] xs;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data([1, 2, 3]));
	assert(v.asMapping["xs"].asSequence.style == CollectionStyle.flow);
	assert(v.asMapping["xs"].asSequence.trailingComma);
	assert(v.asMapping["xs"].asSequence.singleLine);
}

// mappingFormat属性で構造体全体のflow/ケツカンマ/1行出力を指定できる
@safe unittest
{
	@mappingFormat(CollectionStyle.flow, true, true)
	struct Data
	{
		int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	assert(v.asMapping.style == CollectionStyle.flow);
	assert(v.asMapping.trailingComma);
	assert(v.asMapping.singleLine);
}

// keyStyle属性でキーの出力スタイルを指定できる(フィールド単位)
@safe unittest
{
	struct Data
	{
		@keyStyle(ScalarStyle.singleQuoted) int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	assert(v.asMapping.value[0].key.style == ScalarStyle.singleQuoted);
}

// anchor/tag属性でシリアライズ時にアンカー・タグを付与できる
@safe unittest
{
	struct Data
	{
		@anchor("a1") @tag("mytag") int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	assert(v.asMapping["x"].anchorName.get == "a1");
	assert(v.asMapping["x"].tagName.get == "mytag");
}

// 入れ子の構造体・構造体配列もシリアライズできる
@safe unittest
{
	struct Inner { int a; }
	struct Outer { Inner inner; Inner[] list; }
	YamlBuilder builder;
	auto v = builder.serialize(Outer(Inner(1), [Inner(2), Inner(3)]));
	assert(v.asMapping["inner"].getValue!int("a") == 1);
	assert(v.asMapping["list"].asSequence.value[0].getValue!int("a") == 2);
	assert(v.asMapping["list"].asSequence.value[1].getValue!int("a") == 3);
}

// 連想配列(キーはstring)もシリアライズできる
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.serialize(["a": 1, "b": 2]);
	assert(v.type == YamlBuilder.YamlType.mapping);
	assert(v.getValue!int("a") == 1);
	assert(v.getValue!int("b") == 2);
}

// Tupleはシーケンスとしてシリアライズされる
@safe unittest
{
	import std.typecons: tuple;
	YamlBuilder builder;
	auto v = builder.serialize(tuple(1, "two"));
	assert(v.type == YamlBuilder.YamlType.sequence);
	assert(v.getElement!int(0) == 1);
	assert(v.getElement!string(1) == "two");
}

// @kind属性を持つ集約型バリアントを含むSumTypeはマッピングにタグを付与してシリアライズされる
@safe unittest
{
	import std.sumtype: SumType;
	@kind("A") struct VariantA { int a; }
	@kind("B") struct VariantB { string b; }
	alias Variant = SumType!(VariantA, VariantB);
	YamlBuilder builder;
	auto v1 = builder.serialize(Variant(VariantA(1)));
	assert(v1.getValue!string("$type") == "A");
	assert(v1.getValue!int("a") == 1);
	auto v2 = builder.serialize(Variant(VariantB("x")));
	assert(v2.getValue!string("$type") == "B");
	assert(v2.getValue!string("b") == "x");
}

// プリミティブ型のみからなるSumTypeはそのままシリアライズされる
@safe unittest
{
	import std.sumtype: SumType;
	alias Variant = SumType!(int, string);
	YamlBuilder builder;
	auto v1 = builder.serialize(Variant(1));
	assert(v1.type == YamlBuilder.YamlType.integer);
	auto v2 = builder.serialize(Variant("x"));
	assert(v2.type == YamlBuilder.YamlType.string);
}

// @convBy属性(voile.attr)で変換プロキシを通した値をシリアライズできる
@safe unittest
{
	static struct Proxy
	{
		static string to(int v) @safe { return v.to!string; }
		static int from(string v) @safe { return v.to!int; }
	}
	struct Data
	{
		@convBy!Proxy int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(42));
	assert(v.getValue!string("x") == "42");
}

// バイナリ型(immutable(ubyte)[])はBase64URL文字列としてシリアライズされる
@safe unittest
{
	struct Data
	{
		immutable(ubyte)[] bin;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data([0, 1, 2, 3, 255]));
	assert(v.asMapping["bin"].type == YamlBuilder.YamlType.string);
}

// toYaml(Builder引数あり)/fromYamlフックが定義されている型はそちらが優先される
@safe unittest
{
	static struct Data
	{
		int x;
		YamlBuilder.YamlValue toYaml(YamlBuilder b) const @safe
		{
			return b.make(x * 2);
		}
		static Data fromYaml(in YamlBuilder.YamlValue v) @safe
		{
			return Data(v.get!int / 2);
		}
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(21));
	assert(v.get!int == 42);
}

// toYaml(引数なし)/fromYamlフックも検出される
@safe unittest
{
	static struct Data
	{
		int x;
		YamlBuilder.YamlValue toYaml() const @safe
		{
			YamlBuilder b;
			return b.make(x + 1);
		}
		static Data fromYaml(in YamlBuilder.YamlValue v) @safe
		{
			return Data(v.get!int - 1);
		}
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(9));
	assert(v.get!int == 10);
}

// YamlValueを渡した場合はdeepCopyされる(独立したコピーになる)
@safe unittest
{
	YamlBuilder builder;
	auto src = builder.make(["a": 1]);
	auto v = builder.serialize(src);
	assert(v.getValue!int("a") == 1);
	assert(&v.asMapping.value[0] !is &src.asMapping.value[0]);
}

// ============================================================================
// Deserializer のユニットテスト
// ============================================================================

// 単純な構造体へのデシリアライズ(serialize()との往復)
@safe unittest
{
	struct Data
	{
		int x;
		string y;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1, "hello"));
	auto dst = builder.deserialize!Data(v);
	assert(dst == Data(1, "hello"));
}

// @ignore属性が付与されたメンバーはデシリアライズされず既定値のまま
@safe unittest
{
	struct Data
	{
		int x;
		@ignore int y = 99;
	}
	YamlBuilder builder;
	auto v = builder.parse("x: 1\ny: 2\n");
	auto dst = builder.deserialize!Data(v);
	assert(dst.x == 1);
	assert(dst.y == 99);
}

// @name属性で指定したキー名から値を取得する
@safe unittest
{
	struct Data
	{
		@name("renamed") int x;
	}
	YamlBuilder builder;
	auto v = builder.parse("renamed: 5\n");
	auto dst = builder.deserialize!Data(v);
	assert(dst.x == 5);
}

// @essential属性が付与されたメンバーに対応するキーが無い場合は
// deserialize()がfalseを返す(例外はdeserializeImpl()側で送出される)
@safe unittest
{
	struct Data
	{
		@essential int x;
	}
	YamlBuilder builder;
	auto v = builder.parse("y: 1\n");
	Data dst;
	assert(!builder.deserialize(v, dst));
}

// 入れ子の構造体・構造体配列もデシリアライズできる(往復確認)
@safe unittest
{
	struct Inner { int a; }
	struct Outer { Inner inner; Inner[] list; }
	YamlBuilder builder;
	auto src = Outer(Inner(1), [Inner(2), Inner(3)]);
	auto v = builder.serialize(src);
	auto dst = builder.deserialize!Outer(v);
	assert(dst == src);
}

// 連想配列(キーはstring)もデシリアライズできる(往復確認)
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.serialize(["a": 1, "b": 2]);
	auto dst = builder.deserialize!(int[string])(v);
	assert(dst["a"] == 1);
	assert(dst["b"] == 2);
}

// Tupleもデシリアライズできる(往復確認)
@safe unittest
{
	import std.typecons: tuple;
	YamlBuilder builder;
	auto src = tuple(1, "two");
	auto v = builder.serialize(src);
	auto dst = builder.deserialize!(typeof(src))(v);
	assert(dst == src);
}

// @kind属性付きSumTypeは往復でバリアント種別を復元できる
@safe unittest
{
	import std.sumtype: SumType, match;
	@kind("A") struct VariantA { int a; }
	@kind("B") struct VariantB { string b; }
	alias Variant = SumType!(VariantA, VariantB);
	YamlBuilder builder;
	auto v1 = builder.serialize(Variant(VariantA(1)));
	auto dst1 = builder.deserialize!Variant(v1);
	assert(dst1.match!((VariantA a) => a.a == 1, (VariantB b) => false));
	
	auto v2 = builder.serialize(Variant(VariantB("x")));
	auto dst2 = builder.deserialize!Variant(v2);
	assert(dst2.match!((VariantA a) => false, (VariantB b) => b.b == "x"));
}

// プリミティブ型のみからなるSumTypeも往復できる
@safe unittest
{
	import std.sumtype: SumType, match;
	alias Variant = SumType!(int, string);
	YamlBuilder builder;
	auto v1 = builder.serialize(Variant(10));
	auto dst1 = builder.deserialize!Variant(v1);
	assert(dst1.match!((int i) => i == 10, (string s) => false));
	
	auto v2 = builder.serialize(Variant("hi"));
	auto dst2 = builder.deserialize!Variant(v2);
	assert(dst2.match!((int i) => false, (string s) => s == "hi"));
}

// @convBy属性(voile.attr)で変換プロキシを通した値をデシリアライズできる
@safe unittest
{
	static struct Proxy
	{
		static string to(int v) @safe { return v.to!string; }
		static int from(string v) @safe { return v.to!int; }
	}
	struct Data
	{
		@convBy!Proxy int x;
	}
	YamlBuilder builder;
	auto v = builder.parse("x: \"42\"\n");
	auto dst = builder.deserialize!Data(v);
	assert(dst.x == 42);
}

// バイナリ型(immutable(ubyte)[])は往復でBase64URLデコードされる
@safe unittest
{
	struct Data
	{
		immutable(ubyte)[] bin;
	}
	YamlBuilder builder;
	auto src = Data([0, 1, 2, 3, 255]);
	auto v = builder.serialize(src);
	auto dst = builder.deserialize!Data(v);
	assert(dst == src);
}

// toYaml/fromYamlフックが定義されている型は往復でそちらが使われる
@safe unittest
{
	static struct Data
	{
		int x;
		YamlBuilder.YamlValue toYaml(YamlBuilder b) const @safe
		{
			return b.make(x * 2);
		}
		static Data fromYaml(in YamlBuilder.YamlValue v) @safe
		{
			return Data(v.get!int / 2);
		}
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(21));
	auto dst = builder.deserialize!Data(v);
	assert(dst.x == 21);
}

// YamlValueへのデシリアライズはdeepCopyされる
@safe unittest
{
	YamlBuilder builder;
	auto v = builder.parse("x: 1\n");
	auto dst = builder.deserialize!(YamlBuilder.YamlValue)(v);
	assert(dst.getValue!int("x") == 1);
}

// parseからserialize/deserializeで構造体を往復できる統合テスト
@safe unittest
{
	struct Person
	{
		string name;
		int age;
		@ignore string cache;
	}
	YamlBuilder builder;
	auto v = builder.parse("name: Alice\nage: 30\n");
	auto p = builder.deserialize!Person(v);
	assert(p.name == "Alice");
	assert(p.age == 30);
	
	p.age = 31;
	auto v2 = builder.serialize(p);
	assert(v2.getValue!int("age") == 31);
}
// 総合ラウンドトリップテスト(コメント・アンカー・ブロックスカラー・
// flowコレクション・ケツカンマ・各種数値表記を含む合成サンプル)
@safe unittest
{
	enum src = `# root comment
name: Alice # trailing comment
tags: [a, b, c,]
scores:
  - 1
  - 2
  - 3
address: &addr
  city: Tokyo
  zip: "100-0001"
address2: *addr
bio: |
  Hello
  World
note: >
  single line note
hex: 0x1A
oct1: 0o17
float1: 3.14
float2: 1.5e10
flag: true
nothing: null
# dangling comment at end
`;
	YamlBuilder builder;
	auto v = builder.parse(src);
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == src, "Result:\n" ~ app.data ~ "\n----\nExpected:\n" ~ src);
}

// インラインスカラー値へのアンカーがstringifyで往復する
@safe unittest
{
	enum src = "a: &x 1\nb: *x\n";
	YamlBuilder builder;
	auto v = builder.parse(src);
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == src, "Result:\n" ~ app.data ~ "\n----\nExpected:\n" ~ src);
}

// flowシーケンス要素へのアンカーがstringifyで往復する
@safe unittest
{
	enum src = "a: [&x 1, 2, 3]\n";
	YamlBuilder builder;
	auto v = builder.parse(src);
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == src, "Result:\n" ~ app.data ~ "\n----\nExpected:\n" ~ src);
}

// 明示タグ単体・タグとアンカーの組み合わせがstringifyで往復する
@safe unittest
{
	enum src = "a: !mytag value\nb: !!str hello\nc: &x !mytag value2\n";
	YamlBuilder builder;
	auto v = builder.parse(src);
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == src, "Result:\n" ~ app.data ~ "\n----\nExpected:\n" ~ src);
}

// 既知の制限: ルートレベルのブロックマッピングがキーと同じ行以外の
// 位置にアンカーを持つケース(「ドキュメント本体の前に独立したアンカー
// 行を置く」構文)は、現状のパーサーは非対応。root直下のアンカーは
// stringify側は`putYamlBlockNodeImpl`で対応済みだが、パース側は未対応
// (値の一部としてのアンカー`key: &name ...`や`key: &name\n  ...`は
// 上記テストの通り対応済み)

// `@anchor`/`@tag`属性でシリアライズした値のタグは
// `!!`プレフィックスを補って出力される(`tag()`UDAはプレフィックス無しの
// 名称を格納する契約のため、パーサーが格納する生トークンとは形式が異なる。
// `putYamlAnchorTagPrefixImpl`のdocコメント参照)
@safe unittest
{
	struct Data
	{
		@anchor("a1") @tag("mytag") int x;
	}
	YamlBuilder builder;
	auto v = builder.serialize(Data(1));
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	assert(app.data == "x: &a1 !!mytag 1\n", "Result:\n" ~ app.data);
}
// Serializer/Deserializer総合テスト(構造体・SumType・配列・連想配列・
// Tuple・変換UDA・toYaml/fromYamlフックを組み合わせた実際的な使用例)
@safe unittest
{
	import std.datetime: SysTime, DateTime;
	import std.sumtype: SumType;
	import std.typecons: tuple;
	YamlBuilder builder;
	auto app = appender!(char[])();
	
	@kind("Data1") struct Data1
	{
		int a;
		int b;
	}
	auto dat1 = Data1(1, 3);
	auto v = builder.serialize(dat1);
	builder.toPrettyString(app, v);
	auto expected = "a: 1\nb: 3\n";
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	auto dat1b = builder.deserialize!Data1(builder.parse(expected));
	assert(dat1b.a == dat1.a);
	assert(dat1b.b == dat1.b);
	
	alias ST = SumType!(Data1, int);
	// convStr!T(...)/converter!(T1,T2)(...)をUDAとしてインラインの関数
	// リテラル引数付きで直接呼び出すと、内部の関数ポインタキャスト
	// (`T1 function(string)` → `T1 function(in string)`)がCTFEで
	// 評価不能というコンパイラの制限に抵触する(D言語側の既知の制約)。
	// そのため名前付きヘルパー関数を介して呼び出す。
	static auto convSysTimeStr() @safe
	{
		return convStr!SysTime(
			src => SysTime.fromISOExtString(src),
			src => src.toISOExtString());
	}
	static auto convSysTimeYaml() @safe
	{
		return converter!(SysTime, YamlValue)(
			src => SysTime.fromISOExtString(src.get!string),
			src => makeYaml(src.toISOExtString()));
	}
	static auto convSysTimeBin() @safe
	{
		return converter!(SysTime, immutable(ubyte)[])(
			(src) => SysTime.fromISOExtString(cast(string)src),
			(src) => cast(immutable(ubyte)[])(src.toISOExtString()));
	}
	struct Data2
	{
		YamlValue val1;
		int a;
		@name("float_b") float b;
		bool c;
		void* voidData; // ignore as undefined
		immutable(ubyte)[] bin;
		typeof(null) nul;
		string[] strlist;
		string[string] aa;
		Tuple!(int, string) tp;
		@convSysTimeStr SysTime tim1;
		@convSysTimeYaml SysTime tim2;
		@convSysTimeBin SysTime tim3;
		static struct DataA
		{
			int a;
			YamlValue toYaml(YamlBuilder b) const @safe => b.make(a);
			static DataA fromYaml(in YamlValue v) @safe => DataA(v.get!int);
		}
		DataA dataA;
		static assert(hasConvertYamlMethodA!DataA);
		static struct DataB
		{
			int a;
			YamlValue toYaml() const @safe => makeYaml(a);
			static DataB fromYaml(in YamlValue v) @safe => DataB(v.get!int);
		}
		DataB dataB;
		static assert(hasConvertYamlMethodB!DataB);
		ST stVal1;
		ST stVal2;
	}
	auto dat2 = Data2(builder.deepCopy(v), 1, 2, true, null,
		[1, 2, 3, 4], null, ["a", "b"], ["t1": "t2"], tuple(10, "aaa"),
		SysTime(DateTime(2000, 1, 1)), SysTime(DateTime(2001, 1, 1)),
		SysTime(DateTime(2002, 1, 1)),
		Data2.DataA(10), Data2.DataB(12),
		ST(Data1(1, 2)), ST(16));
	v = builder.serialize(dat2);
	assert(v.asMapping["voidData"].type == YamlBuilder.YamlType.undefined);
	builder.toPrettyString(app, v);
	expected = `
val1:
  a: 1
  b: 3
a: 1
float_b: 2.0
c: true
bin: AQIDBA
nul: null
strlist:
  - a
  - b
aa:
  t1: t2
tp:
  - 10
  - aaa
tim1: 2000-01-01T00:00:00
tim2: 2001-01-01T00:00:00
tim3: MjAwMi0wMS0wMVQwMDowMDowMA
dataA: 10
dataB: 12
stVal1:
  $type: Data1
  a: 1
  b: 2
stVal2: 16
`.chompPrefix("\n").outdent;
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
	app.shrinkTo(0);
	Data2 dat2b;
	builder.deserialize(builder.parse(expected), dat2b);
	v = builder.serialize(dat2b);
	builder.toPrettyString(app, v);
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
}
// 配列要素へのフォーマット属性伝播(文字列scalarStyle・整数
// integralFormat・浮動小数点floatingPointFormatが各要素に適用される)
@safe unittest
{
	struct Data
	{
		@arrayFormat(CollectionStyle.flow, false, true) @scalarStyle(ScalarStyle.singleQuoted)
		string[] ary1;
		@arrayFormat(CollectionStyle.flow, false, true) @integralFormat(true, IntegerBase.decimal)
		int[] ary2;
		@arrayFormat(CollectionStyle.flow, false, true) @integralFormat(false, IntegerBase.hex)
		uint[] ary3;
		@arrayFormat(CollectionStyle.flow, false, true) @floatingPointFormat(false, false, false, false, 3)
		double[] ary4;
	}
	auto dat = Data(["a", "b"], [1, 2], [0xab, 0xcd], [1.2, 3.4]);
	YamlBuilder builder;
	auto v = builder.serialize(dat);
	auto app = appender!(char[])();
	builder.toPrettyString(app, v);
	auto expected = "ary1: ['a', 'b']\nary2: [+1, +2]\nary3: [0xab, 0xcd]\nary4: [1.200, 3.400]\n";
	assert(app.data == expected, "Result:\n" ~ app.data ~ "\nExpected:\n" ~ expected);
}

// `@ignoreIf`をシリアライズ用(1引数)・デシリアライズ用(2引数、現在値+
// 現在のYamlValueを参照)で使い分けられる
@safe unittest
{
	struct Data
	{
		@singleLineAry
		@ignoreIf!((in int[] ary) => ary.length == 0)
		@ignoreIf!((int[] ary, const(YamlValue) v) => v.asMapping["ary"].asSequence.value.length == 0)
		int[] ary;
	}
	auto dat1 = Data([1, 2]);
	auto str1 = dat1.serializeToYamlString();
	assert(str1 == "ary: [1, 2,]\n", "Result: [" ~ str1 ~ "]");
	
	auto dat2 = Data([]);
	auto str2 = dat2.serializeToYamlString();
	assert(str2 == "{}", "Result: [" ~ str2 ~ "]");
	
	static assert(hasIgnoreIf!(Data.ary, int[], const(YamlValue)));
	auto dat3 = Data([1, 2]);
	parseYaml("ary: []").deserializeFromYaml(dat3);
	assert(dat3.ary == [1, 2]);
}

// `@essential`属性が付与されたメンバーに対応するキーがあれば
// 正常にデシリアライズされる(存在しない場合の挙動も別途検証済み)
@safe unittest
{
	struct Data
	{
		@essential int x;
		int y = 99;
	}
	YamlBuilder builder;
	auto v = builder.parse("x: 1\n");
	auto dst = builder.deserialize!Data(v);
	assert(dst.x == 1);
	assert(dst.y == 99);
}

// フィールドを持たない(または全メンバーが`@ignore`の)構造体は
// 空のflowマッピング`{}`としてシリアライズされる(上の`ary.length==0`の
// ケースで`{}`になった理由の裏付け: マッピング自体が空のときのみ`{}`になる)
@safe unittest
{
	struct Empty
	{
	}
	auto str = Empty().serializeToYamlString();
	assert(str == "{}", "Result: [" ~ str ~ "]");
}
// パースエラー時の例外メッセージにline/column情報が正しく含まれる
@safe unittest
{
	YamlBuilder builder;
	{
		// 3行目のインデントにタブ文字が混入している
		enum src = "a: 1\nb:\n\tc: 1\n";
		auto e = collectException!YamlParseException(builder.parse(src));
		assert(e !is null);
		assert(e.msg.canFind("line=3"), e.msg);
	}
	{
		// 2行目でキーが重複している
		enum src = "a: 1\na: 2\n";
		auto e = collectException!YamlParseException(builder.parse(src));
		assert(e !is null);
		assert(e.msg.canFind("line=2"), e.msg);
	}
	{
		// 2行目で未定義のアンカーを参照している
		enum src = "a: 1\nb: *undefined\n";
		auto e = collectException!YamlParseException(builder.parse(src));
		assert(e !is null);
		assert(e.msg.canFind("line=2"), e.msg);
	}
	{
		// 3行目でシングルクォート文字列が閉じられていない
		enum src = "a: 1\nb: 2\nc: 'unterminated\n";
		auto e = collectException!YamlParseException(builder.parse(src));
		assert(e !is null);
		assert(e.msg.canFind("line=3"), e.msg);
	}
}

// エッジケース - 空ドキュメント・空白のみ・コメントのみは`null`
// (`YamlType.nullfied`)になる(既存テストの再確認に加え、
// `parseYaml`自由関数版でも同様に振る舞うことを確認する)
@safe unittest
{
	assert(parseYaml("").type == YamlType.nullfied);
	assert(parseYaml("   \n  \n").type == YamlType.nullfied);
	assert(parseYaml("# just a comment\n").type == YamlType.nullfied);
}

// 既知の制限: 空キー(`: value`のように`?`を伴わない裸のコロンで始まる行)は
// 現状のパーサーでは内部アサーション("Cannot start plain scalar at a
// terminator position")に抵触する。YAML 1.1/1.2仕様上も稀なケース
// (明示キー記法`? \n: value`を使わない空キーの単純平文表現)であり、
// 対応する場合はパーサー側の拡張を別途検討すること。

// エッジケース - 深いネスト(10階層)も正しくパース・シリアライズできる
@safe unittest
{
	enum src = "a:\n b:\n  c:\n   d:\n    e:\n     f:\n      g:\n       h:\n        i:\n         j: deep\n";
	YamlBuilder builder;
	auto v = builder.parse(src);
	assert(v.asMapping["a"].asMapping["b"].asMapping["c"].asMapping["d"].asMapping["e"]
		.asMapping["f"].asMapping["g"].asMapping["h"].asMapping["i"].getValue!string("j") == "deep");
}

// エッジケース - 巨大な整数(long境界値付近)・極小浮動小数点数も
// 誤差なくパースできる
@safe unittest
{
	import std.math: isClose;
	YamlBuilder builder;
	auto v = builder.parse("a: 9223372036854775807\nb: -9223372036854775808\nc: 0.0000001\n");
	assert(v.getValue!long("a") == long.max);
	assert(v.getValue!long("b") == long.min);
	assert(v.getValue!double("c").isClose(0.0000001, 1e-9, 1e-12));
}

// エッジケース - 空文字列・空配列・空マッピングをシリアライズ→
// デシリアライズしても等価性が保たれる
@safe unittest
{
	struct Data
	{
		string s;
		int[] ary;
		string[string] aa;
	}
	auto dat = Data("", [], null);
	auto str = dat.serializeToYamlString();
	auto dat2 = deserializeFromYamlString!Data(str);
	assert(dat2.s == "");
	assert(dat2.ary.length == 0);
	assert(dat2.aa.length == 0);
}
