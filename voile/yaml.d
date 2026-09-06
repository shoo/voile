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

import std.algorithm  : map, filter, among, startsWith, endsWith, canFind, joiner;
import std.array      : Appender, appender, join;
import std.conv       : to, text, parse, ConvException;
import std.conv;
import std.ascii      : isDigit, isHexDigit, isOctalDigit;
import std.exception  : enforce;
import std.format     : format;
import std.meta       : AliasSeq, staticMap, Filter, allSatisfy, staticIndexOf;
import std.range      : isOutputRange, ElementType, repeat;
import std.string     : outdent, splitLines, strip, stripRight, indexOf;
import std.traits     : isIntegral, isFloatingPoint, isSomeString, isArray,
                        isAssociativeArray, isBoolean, Unqual, FieldNameTuple,
                        KeyType, ValueType, isInstanceOf, hasMember,
                        isSigned, isUnsigned, isAggregateType, isDynamicArray,
                        hasElaborateAssign, hasElaborateCopyConstructor,
                        hasElaborateMove, hasElaborateDestructor, hasNested,
                        ReturnType, TemplateArgsOf, lvalueOf, hasUDA, getUDAs;
import std.typecons   : Nullable, nullable, Tuple, isTuple;
import std.sumtype    : SumType, match, isSumType;
import std.utf         : encode;

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
// kind (SumTypeシリアライズ用タグ属性、json5.d と同一)
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
auto kind(string name, string value)
{
	return Kind(name, value);
}

/// ditto
auto kind(string value)
{
	return Kind("$type", value);
}

/// ditto
auto kind(string value)()
{
	return Kind("$type", value);
}

private enum hasKind(T) = hasUDA!(T, Kind);
private enum getKind(T) = getUDAs!(T, Kind)[0];

// --------------------------------------------------------------------------
// converter / converterString 等 (json5.d と同一、型名のみYamlValue参照に変更)
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
auto comment(string cmt, CommentType type = CommentType.line)
{
	return AttrYamlComment(cmt, type);
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
auto scalarStyle(ScalarStyle style)
{
	return AttrYamlScalarStyle(style);
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
auto integralFormat(bool positiveSign = false, IntegerBase base = IntegerBase.decimal)
{
	return AttrYamlIntegralFormat(positiveSign, base);
}

// --------------------------------------------------------------------------
// floatingPointFormat 属性（json5.d と同一）
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
	size_t precision           = 0)
{
	return AttrYamlFloatingPointFormat(
		leadingDecimalPoint, tailingDecimalPoint, positiveSign, withExponent, precision);
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
	bool            singleLine    = false)
{
	return AttrYamlArrayFormat(style, trailingComma, singleLine);
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
	bool            singleLine    = false)
{
	return AttrYamlMappingFormat(style, trailingComma, singleLine);
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
auto keyStyle(ScalarStyle style)
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
auto anchor(string anchorName)
{
	return AttrYamlAnchor(anchorName);
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
auto tag(string tagName)
{
	return AttrYamlTag(tagName);
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

private enum isYamlValue(T) = isInstanceOf!(YamlValue, T);
private alias builderOf(T) = TemplateArgsOf!(T, YamlValue)[0];

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
		ref inout(Item[]) byKeyValue() inout => items;
		///
		auto prepend(K k, V v) => items = Item(k, v) ~ items;
		///
		auto append(K k, V v) => items ~= Item(k, v);
		///
		bool empty() const => items.length == 0;
		///
		size_t length() const => items.length;
		///
		inout(V)* opIn(K key) inout
		{
			foreach (ref item; items)
			{
				if (item.key == key)
					return &item.value;
			}
			return null;
		}
		///
		ref inout(Item) opIndex(size_t idx) inout => items[idx];
		///
		ref inout(V) opIndex(K key) inout
		{
			if (auto p = this.opIn(key))
				return *p;
			throw new Exception(format("Key '%s' not found", key));
		}
	}
	template Array(T) { enum Array: T[] { init = T[].init } }
	
	auto allocStr()() => String.init;
	auto allocStr()(string s) => cast(String)s;
	auto allocDic(K, V)() => Dictionary!(K, V).init;
	auto allocAry(T)() => Array!T.init;
	
	void clearAry(Ary)(ref Ary ary) @trusted { ary = null; }
	auto copyStr()(in String str) @trusted => cast(String)str[];
}

// ============================================================================
// MARK: - YamlValue
// ============================================================================

/*******************************************************************************
 * ブロックスカラーのchomping指定子（3.4節）
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
		/// パース時の元テキスト（非空ならstringify時に無条件優先。3.3節）
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
		/// パース時の元テキスト（3.3節）
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
		/// パース時の元テキスト（3.3節）
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
		/// パース時の元テキスト（3.3節）
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlBoolean
	{
		///
		bool value;
		/// パース時の元テキスト（`true`/`True`/`yes`/`on` 等。3.3節）
		String raw;
		
		///
		alias value this;
	}
	///
	static struct YamlNull
	{
		/// パース時の元テキスト（`~`/`null`/空文字列 等。3.3節）
		String raw;
	}
	///
	static struct YamlKey
	{
		///
		String value;
		/// キーの出力スタイル（literal/foldedは指定不可。3.1節 keyStyle参照）
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
		/// ぶら下がりコメント（3.7節ルール3）
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
		/// ぶら下がりコメント（3.7節ルール3）
		Array!Comment trailingComments;
		
		///
		alias value this;
	}
	///
	static struct YamlAlias
	{
		/// 参照先アンカー名
		String value;
		/// 参照先ノードのdeepCopy（ヒープ確保。3.5節）
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
	
	Array!Comment  _comments;
	Nullable!String _anchor;
	Nullable!String _tag;
	YamlType       _instance;
	Builder*       _builder;
	this(scope ref Builder builder) @system pure nothrow @nogc
	{
		_builder = &builder;
	}
public:
	// ==========================================================================
	// MARK: - - Constructor/Destructor/Assign
	// ==========================================================================
	/***************************************************************************
	 * 
	 */
	this(T)(T val, scope ref Builder builder) pure return @system
	{
		_builder = &builder;
		opAssign(val);
	}
	
	/***************************************************************************
	 * 
	 */
	~this() pure nothrow @nogc @safe
	{
		if (_builder)
			_builder.dispose(this);
	}
	
	/***************************************************************************
	 * Assign operator
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
	 * 
	 */
	Type type() const nothrow pure @nogc @trusted
	{
		return cast(Type)__traits(getMember, _instance, "tag");
	}
	
	// ==========================================================================
	// MARK: - - Alias Resolution
	// ==========================================================================
	
	/***************************************************************************
	 * エイリアスノードであれば参照先の実体を、そうでなければ自分自身を返す
	 * 
	 * 全アクセサはこのメソッドを経由することで、エイリアスの有無を意識せず
	 * 透過的に値へアクセスできる（3.5節）。エイリアスがさらにエイリアスを
	 * 指す連鎖（`&y *x`のようにエイリアスノード自体にアンカーを付けた場合に
	 * 発生しうる。T18実装時に発覚）にも対応するため、`resolved`が
	 * さらにエイリアス型であれば再帰的に辿る。
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
	 * 
	 */
	ref inout(YamlString) asString() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.string, "Not a string type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.string];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(YamlInteger) asInteger() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.integer, "Not an integer number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.integer];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(YamlUInteger) asUInteger() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.uinteger, "Not an unsigned integer number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.uinteger];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(YamlFloatingPoint) asFloatingPoint() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.floating, "Not a floating point number type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.floating];
	}
	
	/***************************************************************************
	 * 
	 */
	ref inout(YamlBoolean) asBoolean() inout @trusted
	{
		auto vp = &dereference();
		assert(vp.type == Type.boolean, "Not a boolean type");
		return __traits(getMember, vp._instance, "storage").tupleof[cast(size_t)Type.boolean];
	}
	
	/***************************************************************************
	 * 
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
	 * 
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
	 * Get value as the given type
	 * 
	 * If the type conversion is not possible, return the given default value (or T.init if not given).
	 * エイリアスは自動的に解決される（3.5節）。
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
	 * Add a line comment/trailing comment
	 */
	void addComment(in char[] comment, CommentType type = CommentType.line)
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
	bool isLineComment(size_t idx) const @trusted
	{
		assert(idx < _comments.length, "Comment index out of range");
		return __traits(getMember, _comments[idx], "tag") == 0;
	}
	/// ditto
	bool isTrailingComment(size_t idx) const @trusted
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
}

// ============================================================================
// MARK: Builder
// ============================================================================

/*******************************************************************************
 * YAMLパースエラー
 * 
 * 通常の `Exception` と区別して捕捉できるよう、専用の例外型として定義する（3.2節）。
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
	// MARK: - - Builder Factory (T30 で本実装。dispose()に加え、T18が依存するため
	// deepCopy()/copyStr()のみ前倒しで実装済み。make()/undefinedValue()/
	// emptyArray()/emptyObject()はT30で実装する)
	// ==========================================================================
	// 以下は全てライブラリ利用者が直接呼び出すことを想定しない内部実装。
	// 公開APIは Export Types セクション（自由関数群）を経由して提供する。
	
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
	 * 使えるよう、JSON5の`copyStr()`と同じ形で用意している。
	 */
	auto copyStr()(in String str) @trusted => cast(String)str[];
	
	/***************************************************************************
	 * コメント1件の複製を作る（`_comments`配列の複製時に使用）
	 */
	YamlValue.Comment copyComment()(in YamlValue.Comment c) @trusted
	{
		return c.match!(
			(ref const(YamlValue.LineComment) lc) => YamlValue.Comment(YamlValue.LineComment(copyStr(lc.value))),
			(ref const(YamlValue.TrailingComment) tc) => YamlValue.Comment(YamlValue.TrailingComment(copyStr(tc.value))));
	}
	
	/***************************************************************************
	 * ノードの深いコピーを作成する（T30予定だが、T18のエイリアス解決
	 * （3.5節: `*name`出現時に`YamlAlias(name, 該当ノードのdeepCopy)`を生成する）
	 * が依存するため前倒しで実装する。JSON5の`deepCopy()`とほぼ同じ構成に、
	 * YAML固有の`_anchor`/`_tag`フィールドおよび`YamlAlias`型・
	 * `trailingComments`（3.7節）の複製を追加したもの）
	 * 
	 * コレクション（YamlSequence/YamlMapping）は内部の`Array`/`Dictionary`を
	 * 新規に確保し直し、各要素を再帰的に複製する。スカラーの`String`フィールドは
	 * `copyStr()`経由（既定アロケータでは単なるキャスト）で複製したことにする。
	 * `_comments`・`_anchor`・`_tag`も複製対象に含める。`YamlAlias`の場合は
	 * `resolved`もヒープに再確保し、再帰的に複製することで元のエイリアス連鎖と
	 * 完全に独立させる。
	 * 
	 * 戻り値の`_builder`は複製元のものではなく、本メソッドを呼び出した
	 * builder自身（`this`）に設定される（JSON5の`deepCopy()`と同じ、
	 * `YamlValueImpl(value, this)`コンストラクタを使う方式）。
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
			(ref const(YamlValue.UndefinedValue) _) => YamlValue.init);
		ret._comments = allocAry!(YamlValue.Comment);
		foreach (ref c; src._comments[])
			ret._comments ~= copyComment(c);
		if (!src._anchor.isNull)
			ret._anchor = nullable(copyStr(src._anchor.get));
		if (!src._tag.isNull)
			ret._tag = nullable(copyStr(src._tag.get));
		return ret;
	}
	
	// ==========================================================================
	// MARK: - - Parser
	// ==========================================================================
	// T10: 字句解析共通部品（インデント管理・行列カウンタ・改行コード処理・タブ禁止検査）
	
	/***************************************************************************
	 * UTF-8 BOM（`\uFEFF`）をスキップする
	 * 
	 * ストリーム先頭でのみ呼び出すこと（3.2節 8.）。それ以外の位置にBOMが
	 * 出現した場合の扱いは呼び出し側（`parse()`、T1Aで実装）の責務とする。
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
	 * `\n`・`\r\n`・`\r` はいずれも1回の改行として正規化して扱う（3.2節、
	 * 出力時は既定で`\n`に統一する方針と対）。
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
	 * 送出する（3.2節 2.、YAML仕様準拠：インデントへのタブ使用は禁止）。
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
	
	// T11: plainスカラーパーサ（終端判定ロジック含む）
	
	/***************************************************************************
	 * 現在位置がplainスカラーの終端であるかどうかを判定する
	 * 
	 * 以下をすべて終端条件として判定する（3.2節4.、design 4.2節 T11）:
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
	 * 判定は呼び出し側（ブロック/フローコレクションパーサ、T15/T16）の責務であり、
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
	 * 折り畳む（design 3.2節の簡易方針）。継続行のインデントが `minIndent` 未満の
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
						// コメント行はスカラーの継続とはみなさない（T17bで発見・修正。
						// 進捗ドキュメントの実装メモ参照）。この行を消費せずに
						// 折り畳み探索を打ち切り、スカラーをここで終了させる。
						// コメント自体は後でその位置から`skipBlankAndCommentLinesImpl`
						// 等が改めて読み取り、次の実トークンのleading commentとして
						// 蓄積する。
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
	
	// T12: quoted文字列パーサ（single/double、エスケープ規則）
	
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
	 * 半角スペース1つに折り畳む（design 3.2節の簡易方針）。
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
	
	// T13: ブロックスカラーパーサ（literal/folded、chomping、明示インデント）
	
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
	 *   間に空行が挟まる場合はその空行の数だけ改行として残す（design 3.4節の方針、
	 *   「より深くインデントされた行は折り畳まない」という仕様上の例外は本実装では
	 *   簡略化のため区別しない）。
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
	
	// T14: スカラー型解決ロジック（resolveScalarType、暗黙null含む）
	
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
	 * 解決対象に含める（3.3節、design doc Y10）。判定順序は
	 * `null候補 → bool候補 → 数値候補(10進/16進/8進/2進/浮動小数点) → それ以外は文字列`
	 * とする（design 4.2節 T14）。
	 * 
	 * この関数は **plainスカラーの生テキストにのみ** 適用すること。quoted文字列や
	 * ブロックスカラーは明示的な区切り記法によって常に文字列型として確定するため、
	 * この関数を通す必要はない（呼び出し側、T16での統合時の注意点）。
	 * 
	 * 解決された型の `raw` フィールドには常に元のテキストがそのまま保持される
	 * （3.3節のraw保持方針）。数値以外にも到達できなかった場合は文字列として扱う。
	 * Params:
	 *      dst = 解決結果の格納先
	 *      raw = plainスカラーの生テキスト（空文字列も許容し、暗黙のnullとして扱う）
	 * Returns:
	 *      解決された型
	 */
	YamlType resolveScalarTypeImpl(ref YamlValue dst, in char[] raw) @safe
	{
		// 空文字列: 暗黙のnull（Y11）
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
		
		// 10進整数 / 浮動小数点数（手書き状態機械、JSON5のparseNumberImplに準拠）
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
	 * 符号なしで `long.max` を超える場合のみ `YamlUInteger` とする
	 * （JSON5の`parseNumberImpl`と同じ判定方針）。桁溢れ等でパースに失敗した
	 * 場合は数値としての解決を諦め、文字列として扱う。
	 */
	private YamlType resolveIntegerImpl(ref YamlValue dst, in char[] raw, in char[] digits,
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
	 * `value`（実際の内容）と`raw`（3.3節のraw保持方針）の両方に元のテキストを設定する。
	 * plainスカラーの文字列解決では両者は常に一致する（数値等と異なり、値と表記が
	 * 分離しないため）。
	 */
	private YamlType resolveAsStringImpl(ref YamlValue dst, in char[] raw) @safe
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
	
	// T15: flowコレクションパーサ（`[...]`/`{...}`、ケツカンマ許容）
	
	/***************************************************************************
	 * flowコンテキスト内の区切り空白・改行を読み飛ばす
	 * 
	 * `[`/`{` の直後、`,` の前後、`]`/`}` の直前など、要素と要素の間の
	 * 構造的な区切りで使用する。plainスカラーの折り畳み（`parsePlainScalarImpl`）
	 * と異なり、ここで読み飛ばす空白・改行は内容ではなく区切りそのものであるため、
	 * スペース1つへの折り畳みは行わず単純に読み飛ばす。
	 * コメント（`#`）に遭遇した場合はその本文を`_pendingComments`に蓄積する
	 * （T17b）。flow文脈のコメントはインデントに意味がないため、記録する
	 * `indentLen`は常に0とする（`attachAllPendingTrailingCommentsImpl`は
	 * インデント比較をしないため実際には参照されない）。要素自身と同一行で
	 * カンマの前に書かれたコメント（例: `[1 # comment\n, 2]`）も、そのカンマ直後の
	 * 次要素のleading commentとして扱う簡略化を採用している（3.7節ルール2の
	 * 「同一行なのでtrailing commentとすべき」という厳密な解釈とは異なるが、
	 * この記法は極めて稀であるため実装の単純さを優先した。進捗ドキュメント参照）。
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
	 * 先頭文字により以下へ振り分ける（design 3.2節3.の優先順位に準拠）:
	 * `[` → `parseFlowSequenceImpl` / `{` → `parseFlowMappingImpl` /
	 * `'` → `parseSingleQuotedImpl` / `"` → `parseDoubleQuotedImpl` /
	 * それ以外 → `parsePlainScalarImpl` の結果を `resolveScalarTypeImpl` で解決する。
	 * Params:
	 *      dst       = パース結果の格納先
	 *      src       = 現在位置からの文字列（flowノードとして開始可能な位置であること）
	 *      line      = 行番号（改行のたびに更新される）
	 *      col       = 列番号（消費した文字数だけ更新される）
	 *      minIndent = 内部のplainスカラーが複数行に折り畳まれる際の最小インデント
	 *                  （呼び出し元のブロック文脈から引き継ぐ。3.2節1.の契約に準拠）
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
	 * 許容する（ケツカンマ、design Y2・R6）。YAML仕様が認める
	 * シーケンス内マッピング省略記法（`[a: 1]` のような `ns-flow-pair`）には
	 * 対応しない（設計スコープ外。進捗ドキュメントの実装メモを参照）。
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
	 * 1つだけ許容する（ケツカンマ、design Y2・R6）。キーはスカラー
	 * （plain/quoted）のみをサポートし、`[`/`{`/`?` で始まる非スカラー・
	 * 明示キーは非対応としてエラーにする（Y9）。値を省略したエントリ
	 * （`{a, b: 1}` の `a`）はYAML仕様の `e-node` に対応する暗黙のnullとして
	 * 解決し、キー自体を省略した `{: 1}` のような記法（同じく仕様上の
	 * `e-node ":" ...`）も空文字列キーとして受理する。マッピングキーの重複は
	 * パースエラーとする（Y12、design 3.2節7.）。
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
	
	// T16: blockコレクションパーサ（シーケンス `- `、マッピング `key:`、ネスト処理、キー重複検出）
	
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
	 * 存在するかどうかを判定する（コロン先読み、design 3.2節3.）
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
	 * コメントのみの行は、その本文とインデント量を`_pendingComments`に蓄積する
	 * （T17b、3.7節ルール1）。実際にどのノードへ付与するかは
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
	 *    委ねることで自然に対応できる。design上、マッピングの値としては
	 *    `key: sub: value`のような同一行ネストは通常のYAMLでは想定されない書き方だが、
	 *    実装を単純化するため本実装では区別せず同じ経路で扱う簡略化を採用した）
	 * 2. 改行後、より深いインデントの行がある場合 → その行から`parseBlockNodeImpl`
	 *    でネストした値としてパース
	 * 3. （`allowSameIndentSequence`が`true`の場合のみ）改行後、エントリ自身と
	 *    同じインデントでblockシーケンス項目（`- `）が続く場合 → YAML仕様が
	 *    認める「マッピング値としてのシーケンスはキーと同じインデントでもよい」
	 *    規則（design Y1関連）に対応し、`parseBlockSequenceImpl`でパースする
	 *    （blockマッピングの値としてのみ許可。シーケンス項目自身の値には適用しない）
	 * 4. いずれにも該当しない場合 → 暗黙のnull（Y11）。この場合、後続行の
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
	 * `minIndent`引数はT10のシグネチャ統一契約により受け取るが、確立インデントは
	 * 呼び出し時点の`col`から自己導出するため本体では使用しない
	 * （`parseSingleQuotedImpl`等と同様の理由。3.2節1.参照）。
	 * 
	 * ループ継続判定:
	 * - 次行のインデントが`ownIndent`未満 → シーケンス終了（正常、呼び出し元へ戻す）
	 * - 次行のインデントが`ownIndent`と同じで`-`項目が続く → 継続
	 * - 次行のインデントが`ownIndent`と同じだが`-`項目でない → シーケンス終了
	 *   （正常。例えばマッピングキーの値として同一インデントで書かれたシーケンスが
	 *   終わり、後続のマッピングキーに制御を戻すケースに対応。design Y1関連）
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
	 * 分かりやすい構文エラーとして報告する（本体の定義はT17bで拡張され
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
	 * 非対応としてエラーにする（Y9）。マッピングキーの重複はパースエラーとする
	 * （Y12、design 3.2節7.）。`minIndent`引数は`parseBlockSequenceImpl`と同様の
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
	 * （design 3.2節3.の優先順位に準拠、文書区切り記号の判定はT1Aで対応するため
	 * ここでは扱わない）:
	 * 1. blockスカラー（`|`/`>`）
	 * 2. flowコレクション（`[`/`{`）
	 * 3. blockシーケンス項目（`-` + 空白/改行/EOF）
	 * 4. 明示キー（`?`） → 非対応としてエラー（Y9）
	 * 5. マッピングキー候補（コロン先読み、`lineHasMappingColonImpl`）
	 * 6. quoted文字列（単独の値として。マッピングキーでないことは5.で除外済み）
	 * 7. plainスカラー（既定）
	 * 
	 * 「葉」となる値のうちflowコレクション（2.）・quoted文字列（6.）・
	 * plainスカラー（7.）をパースした直後は`expectEndOfLineImpl`で行末までの
	 * 残存内容を検証する。plainスカラーの複数行折り畳みが埋め込みの
	 * セパレータ（コロン+空白等）で行の途中に停止するケースや、flow
	 * コレクションの閉じ括弧の直後に余分な文字が続くケースがあるため
	 * （実装メモ参照）。一方、blockスカラー（1.）とblockコレクション（3./5.）は
	 * インデントに基づいて行境界で必ず終了する（行の途中で止まることがない）ため
	 * ここでは検証しない（検証してしまうと、ネストした値の直後に続く
	 * 「呼び出し元の次のエントリ」を誤って「同一行の残存ゴミ」と誤検知してしまう）。
	 * 
	 * 冒頭で`skipBlankAndCommentLinesImpl`を呼び、先頭の空行・コメント行を
	 * 自ら読み飛ばしてから内容を判定する。通常は呼び出し元
	 * （`parseBlockEntryValueImpl`）が既に読み飛ばし済みのため冪等な無駄呼び出しに
	 * なるだけだが、これにより「ドキュメント先頭のコメント」のように、
	 * 事前の読み飛ばしを経由せず直接本関数が呼ばれるケース（T1Aでのルート
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
	
	// T17b: コメント位置復元ロジック（design 3.7節ルール1〜4）
	
	/***************************************************************************
	 * 保留中のコメント1件を表す内部構造体
	 * 
	 * `indentLen`はそのコメント自身の行頭からの空白文字数（`measureIndentImpl`と
	 * 同じ単位）。flow文脈で捕捉されたコメントについては、flowコレクションの
	 * 境界は角括弧の対応により曖昧さなく決まるため、この値は意味を持たない
	 * （3.7節ルール4のインデント比較はblock文脈のdanglingコメント判定にのみ使う）。
	 */
	private static struct PendingComment
	{
		///
		String text;
		///
		size_t indentLen;
	}
	
	/// 保留中コメントのキュー（`skipBlankAndCommentLinesImpl`/`skipFlowSpacingImpl`で
	/// 蓄積され、`attachPendingLeadingCommentsImpl`等で取り出される）
	private Array!PendingComment _pendingComments;
	
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
	 * 保留中のリーディングコメント（3.7節ルール1）をすべて`dst`に付与し、
	 * キューを空にする
	 * 
	 * `parseBlockNodeImpl`/`parseFlowNodeImpl`の冒頭で無条件に呼び出す。
	 * `dst`はこの時点でまだ実際の値を代入されていない状態でもよい
	 * （`opAssign`は`_comments`を保持したまま`_instance`のみ差し替えるため、
	 * 後から`dst = 実際の値;`としても本メソッドで付与したコメントは残る。
	 * 3.2節のコーディング規約に基づく実装メモ参照）。
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
	 * （blockコレクションのdangling comment、3.7節ルール3・4）
	 * 
	 * インデントが`ownIndent`未満のコメントはこのコレクションには属さず、
	 * より外側の呼び出し元が後で解決すべきものとしてキューに残す
	 * （T17a調査結果: gopkg.in/yaml.v3の実バグ事例を踏まえ、単純にキュー全体を
	 * 消費してしまわないよう設計。進捗ドキュメント参照）。
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
	 * 同一行の末尾コメントがあれば`dst`のtrailing comment（3.7節ルール2）として
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
	
	// T18: アンカー・エイリアスパーサ + anchorTable管理（design 3.5節）
	
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
	
	// T19: 明示タグパーサ（保持のみ、型解決には未使用。design Y6）
	
	/***************************************************************************
	 * 明示タグ（`!`で始まるトークン）を読み取る
	 * 
	 * 型解決には使わず、raw文字列として保持するのみ（Y6）。以下の形式を
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
	
	/// アンカーテーブル（design 3.5節）。`parse()`（T1A）呼び出しごとに
	/// 新規にクリアすべきだが、本タスク時点ではT1A未実装のため各テストは
	/// 新規`YamlBuilder`インスタンスを使うことで暗黙にクリア状態から開始している
	private Dictionary!(string, YamlValue) _anchorTable;
	
	/***************************************************************************
	 * アンカーを登録する（同名アンカーが既にあれば上書きする。再アンカーは
	 * YAML仕様上正当であり、以後の`*name`は最新の定義を参照する）
	 * 
	 * ここではdeepCopyせず値をそのまま登録する（3.5節: deepCopyは`*name`
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
	
	// T1A: parse() 統合（単一ドキュメント、BOM処理、複数ドキュメント構文の明示エラー化）
	
	/// 空白・タブ・改行・EOFのいずれかを判定する（ドキュメント区切り記号の
	/// 終端判定に使う小さな補助関数）
	bool isSpaceOrEolImpl(char c) const pure nothrow @nogc @safe
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}
	
	/***************************************************************************
	 * 複数ドキュメント関連構文（行頭`---`・行頭`...`・`%`ディレクティブ行）が
	 * 現在位置に出現していないかを検証する（Y7、design 3.2節6.）
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
	
public:
	// ==========================================================================
	// MARK: - - Public API (T1Aで parse() を追加。将来T30/T40/T41/T24/T31が
	// make()/serialize()/deserialize()/toPrettyString()/update()を追加し、
	// 最終的にこのセクションへ集約される想定)
	// ==========================================================================
	
	/***************************************************************************
	 * YAML文字列をパースし、ルートノードを返す
	 * 
	 * 単一ドキュメントのみをサポートする（Y7）。以下の場合は
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
}

// ============================================================================
// MARK: - Export Types
// ============================================================================

// 以下は T03 検証用の暫定エイリアス。正式な公開APIは T50 で確定させる。
alias YamlBuilder  = YamlBuilderImpl!YamlDefaultAllocator;
alias YamlValue    = YamlBuilder.YamlValue;

// ============================================================================
// MARK: - Unittests
// ============================================================================

// 注: Builder Factory (make() 等) は T30 で実装するため、T03時点の検証では
// YamlValue の公開コンストラクタ (YamlValue(val, builder)) を直接使用する。
// このコンストラクタは @system のため、以下のテストは @system unittest とする。
// T30 完了後、make() 経由の @safe なテストを別途追加する。

/// T03: 基本的なスカラー値の構築とget()
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

/// T03: 配列・連想配列の構築
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

/// T03: コメント操作
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

/// T03: アンカー・タグの設定
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

/// T03: エイリアスのdereference透過アクセス
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

/// T10: skipBOMImpl
@safe unittest
{
	YamlBuilder builder;
	assert(builder.skipBOMImpl("\uFEFFabc") == 3);
	assert(builder.skipBOMImpl("abc") == 0);
	assert(builder.skipBOMImpl("") == 0);
}

/// T10: skipNewlineImpl - 改行なし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 5;
	assert(builder.skipNewlineImpl("abc", line, col) == 0);
	assert(line == 1 && col == 5);
	assert(builder.skipNewlineImpl("", line, col) == 0);
}

/// T10: skipNewlineImpl - 改行コード3種(\n / \r\n / \r)の正規化
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

/// T10: measureIndentImpl - 複数インデント量パターン
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

/// T10: measureIndentImpl - 改行/文字列末尾で計測終了
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	assert(builder.measureIndentImpl("  \nnext", 1, col) == 2);
	col = 1;
	assert(builder.measureIndentImpl("   ", 1, col) == 3);
}

/// T10: measureIndentImpl - タブ混入で例外送出
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

/// T10: 改行コード3種 x インデント量複数パターンの直交組み合わせで行列カウンタを検証
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

/// T11: isPlainScalarTerminator - EOF
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator("", false) == true);
}

/// T11: isPlainScalarTerminator - `key: value` のコロン+空白による終端
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator(": value", false) == true);
	assert(builder.isPlainScalarTerminator(":\tvalue", false) == true);
	assert(builder.isPlainScalarTerminator(":\nvalue", false) == true);
	assert(builder.isPlainScalarTerminator(":", false) == true);
}

/// T11: isPlainScalarTerminator - `key:value` はコロン後ろが空白でないため終端しない
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isPlainScalarTerminator(":value", false) == false);
	assert(builder.isPlainScalarTerminator(":1", false) == false);
}

/// T11: isPlainScalarTerminator - フロー文脈での `,`/`]`/`}` による終端
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

/// T11: isPlainScalarTerminator - 末尾の空白+コメント/改行/EOF
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

/// T11: parsePlainScalarImpl - `key: value` のコロン+空白による終端
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "key: value", line, col, 0, false);
	assert(consumed == 3);
	assert(dst.value[] == "key");
}

/// T11: parsePlainScalarImpl - `key:value` はコロンの後ろが空白でないため終端しない
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "key:value", line, col, 0, false);
	assert(consumed == 9);
	assert(dst.value[] == "key:value");
}

/// T11: parsePlainScalarImpl - フロー文脈内の`,`/`]`/`}`による終端
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

/// T11: parsePlainScalarImpl - 複数行の折り畳み(改行は1スペースに変換)
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

/// T11: parsePlainScalarImpl - 継続行のインデント不足で終端(改行は消費しない)
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

/// T11: parsePlainScalarImpl - 行末の余分な空白はトリムされる
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

/// T11: parsePlainScalarImpl - 行末コメントの手前で終端する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parsePlainScalarImpl(dst, "abc # comment", line, col, 0, false);
	assert(consumed == 3);
	assert(dst.value[] == "abc");
}

/// T12: parseSingleQuotedImpl - 基本のシングルクォート文字列
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

/// T12: parseSingleQuotedImpl - `''`エスケープ(1つのシングルクォートリテラル)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseSingleQuotedImpl(dst, "'it''s'rest", line, col, 0);
	assert(consumed == 7);
	assert(dst.value[] == "it's");
}

/// T12: parseSingleQuotedImpl - バックスラッシュは特別扱いされない(リテラルのまま)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseSingleQuotedImpl(dst, `'a\nb'`, line, col, 0);
	assert(dst.value[] == `a\nb`);
}

/// T12: parseSingleQuotedImpl - 複数行の折り畳み
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

/// T12: parseSingleQuotedImpl - 閉じクォートなしで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseSingleQuotedImpl(dst, "'unterminated", line, col, 0));
}

/// T12: parseDoubleQuotedImpl - 基本のダブルクォート文字列
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

/// T12: parseDoubleQuotedImpl - 名前付きエスケープシーケンス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto consumed = builder.parseDoubleQuotedImpl(dst, `"a\nb\tc\\d\"e"`, line, col, 0);
	assert(dst.value[] == "a\nb\tc\\d\"e");
}

/// T12: parseDoubleQuotedImpl - 16進エスケープ(\x, \u, \U)
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

/// T12: parseDoubleQuotedImpl - 行継続(バックスラッシュ+改行は除去、スペース挿入なし)
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

/// T12: parseDoubleQuotedImpl - エスケープなし改行は半角スペース1つに折り畳む
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

/// T12: parseDoubleQuotedImpl - 不正なエスケープシーケンスで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"\q"`, line, col, 0));
}

/// T12: parseDoubleQuotedImpl - 桁数不足の16進エスケープで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"\u12"`, line, col, 0));
}

/// T12: parseDoubleQuotedImpl - 閉じクォートなしで例外送出
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	assertThrown!YamlParseException(builder.parseDoubleQuotedImpl(dst, `"unterminated`, line, col, 0));
}

/// T13: parseBlockScalarImpl - literalスタイル基本(chomping=clip既定)
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

/// T13: parseBlockScalarImpl - chomping代表例(strip/clip/keep、YAML仕様の例に相当)
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

/// T13: parseBlockScalarImpl - foldedスタイル: 単一改行はスペースに変換
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

/// T13: parseBlockScalarImpl - foldedスタイル: 空行は改行として保持(複数空行)
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

/// T13: parseBlockScalarImpl - 明示インデント指定子
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

/// T13: parseBlockScalarImpl - 明示インデント+chomping指定子(順序を問わない)
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

/// T13: parseBlockScalarImpl - インデント自動検出(最初の非空行から決定)
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlString dst;
	auto src = "|\n    abc\n    def\n";
	builder.parseBlockScalarImpl(dst, src, line, col, 0);
	assert(dst.value[] == "abc\ndef\n");
}

/// T13: parseBlockScalarImpl - 親のインデント以下に戻ったら終了(後続を消費しない)
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

/// T13: parseBlockScalarImpl - 空のブロックスカラー
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

/// T13: parseBlockScalarImpl - ヘッダ行のコメント
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

/// T14: resolveScalarTypeImpl - 型分類のテーブル駆動テスト
/// (Core Schema仕様と1.1互換ケースを1つの配列にまとめて反復実行、design 4.2節 T14方針)
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

/// T14: resolveScalarTypeImpl - 数値の実値と基数の検証
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

/// T14: resolveScalarTypeImpl - 巨大な符号なし整数はYamlUIntegerに解決される
@safe unittest
{
	YamlBuilder builder;
	YamlBuilder.YamlValue dst;
	// long.max を超える値
	auto resolved = builder.resolveScalarTypeImpl(dst, "18446744073709551615"); // ulong.max
	assert(resolved == YamlBuilder.YamlType.uinteger);
	assert(dst.asUInteger.value == ulong.max);
}

/// T14: resolveScalarTypeImpl - raw フィールドが常に元のテキストを保持する
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
		case YamlBuilder.YamlType.nullfied:  break; // YamlNullにはasNull()アクセサが無いためraw検証は省略
		case YamlBuilder.YamlType.undefined:
		case YamlBuilder.YamlType.alias_:
		case YamlBuilder.YamlType.sequence:
		case YamlBuilder.YamlType.mapping:
			assert(0, "unexpected type for scalar resolution");
		}
	}
}

/// T15: skipFlowSpacingImpl - 空白・タブ・改行の読み飛ばし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	auto consumed = builder.skipFlowSpacingImpl("   \t\nabc", line, col);
	assert(consumed == 5);
	assert(line == 2);
	assert(col == 1);
}

/// T15: parseFlowSequenceImpl - 空のflowシーケンス
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

/// T15: parseFlowSequenceImpl - 単純な数値要素のシーケンス
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

/// T15: parseFlowSequenceImpl - ケツカンマを許容する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1, 2, 3,]", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(dst.asSequence.trailingComma);
}

/// T15: parseFlowSequenceImpl - ネストしたflowシーケンス
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

/// T15: parseFlowSequenceImpl - plain/single/doubleクォート要素が混在するシーケンス
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

/// T15: parseFlowSequenceImpl - 複数行にまたがる場合はsingleLineがfalseになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1,\n 2,\n 3]", line, col, 0);
	assert(dst.asSequence.value.length == 3);
	assert(!dst.asSequence.singleLine);
}

/// T15: parseFlowSequenceImpl - 1行に収まる場合はsingleLineがtrueのままになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowSequenceImpl(dst, "[1, 2, 3]", line, col, 0);
	assert(dst.asSequence.singleLine);
}

/// T15: parseFlowSequenceImpl - 未終端の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowSequenceImpl(dst, "[1, 2", line, col, 0));
}

/// T15: parseFlowSequenceImpl - 先頭がいきなり`,`の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowSequenceImpl(dst, "[,1]", line, col, 0));
}

/// T15: parseFlowMappingImpl - 空のflowマッピング
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

/// T15: parseFlowMappingImpl - 単純なキー・値ペア
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

/// T15: parseFlowMappingImpl - ケツカンマを許容する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{a: 1, b: 2,}", line, col, 0);
	assert(dst.asMapping.value.length == 2);
	assert(dst.asMapping.trailingComma);
}

/// T15: parseFlowMappingImpl - 値を省略したエントリは暗黙のnullとして解決される
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

/// T15: parseFlowMappingImpl - キーを省略した`e-node`エントリは空文字列キーになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, "{: 1}", line, col, 0);
	assert(dst.asMapping.value.length == 1);
	assert(dst.asMapping[""].get!int == 1);
}

/// T15: parseFlowMappingImpl - キーの重複はパースエラーになる（Y12）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseFlowMappingImpl(dst, "{a: 1, a: 2}", line, col, 0));
}

/// T15: parseFlowMappingImpl - 非スカラーキーは非対応としてエラーになる（Y9）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowMappingImpl(dst, "{[1]: 2}", line, col, 0));
}

/// T15: parseFlowMappingImpl - シングルクォート・ダブルクォートキー
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseFlowMappingImpl(dst, `{'a': 1, "b": 2}`, line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

/// T15: parseFlowMappingImpl - flowシーケンス・flowマッピングの相互ネスト
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

/// T15: parseFlowMappingImpl - 未終端の場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseFlowMappingImpl(dst, "{a: 1", line, col, 0));
}

/// T15: parseFlowNodeImpl - トップレベルからflowシーケンス/マッピングへ振り分ける
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

/// T16: isBlockSequenceIndicatorImpl - `-`項目インジケータの判定
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

/// T16: isExplicitKeyIndicatorImpl - `?`明示キーインジケータの判定
@safe unittest
{
	YamlBuilder builder;
	assert(builder.isExplicitKeyIndicatorImpl("? a"));
	assert(builder.isExplicitKeyIndicatorImpl("?"));
	assert(!builder.isExplicitKeyIndicatorImpl("?a"));
	assert(!builder.isExplicitKeyIndicatorImpl("abc"));
}

/// T16: lineHasMappingColonImpl - コロン先読みによるマッピング判定
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

/// T16: skipBlankAndCommentLinesImpl - 空行・コメント行の読み飛ばし
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	auto consumed = builder.skipBlankAndCommentLinesImpl("\n\n# comment\n  # indented comment\nkey: value", line, col);
	assert(line == 5);
	assert(col == 1);
	assert("\n\n# comment\n  # indented comment\nkey: value"[consumed .. $] == "key: value");
}

/// T17b: skipBlankAndCommentLinesImpl - コメント本文とインデント量を`_pendingComments`に蓄積する
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

/// T16: parseBlockSequenceImpl - 単純なblockシーケンス
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

/// T16: parseBlockMappingImpl - 単純なblockマッピング
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

/// T16: parseBlockNodeImpl - より深いインデントによるネストしたマッピング
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

/// T16: parseBlockNodeImpl - マッピング値としてのシーケンスはキーと同じインデントでもよい
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

/// T16: parseBlockNodeImpl - マッピング値としてのシーケンスはより深いインデントでもよい
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

/// T16: parseBlockNodeImpl - blockシーケンス項目としてのインラインマッピング（`- key: value`）
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

/// T16: parseBlockNodeImpl - コンパクトなネストシーケンス（`- - 1`）
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

/// T16: parseBlockNodeImpl - マッピング値としてのflowコレクション
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

/// T16: parseBlockNodeImpl - マッピング値としてのblockリテラルスカラー（同一行`|`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: |\n  line1\n  line2\nb: 2", line, col, 0);
	assert(dst.getValue!string("a") == "line1\nline2\n");
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - マッピング値としてのblockリテラルスカラー（独立行`|`）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a:\n  |\n    line1\n    line2\nb: 2", line, col, 0);
	assert(dst.getValue!string("a") == "line1\nline2\n");
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - 深いネスト構造（マッピング・シーケンスの入れ子）
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

/// T16: parseBlockNodeImpl - 暗黙のnull値
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a:\nb: 2", line, col, 0);
	assert(dst.asMapping["a"].type == YamlBuilder.YamlType.nullfied);
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - シングル/ダブルクォートキー
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "'a': 1\n\"b\": 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - 空行・コメント行の混在
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1\n\n# comment\nb: 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - 値の直後の行末コメント
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: 1 # comment\nb: 2", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.getValue!int("b") == 2);
}

/// T16: parseBlockNodeImpl - シーケンス項目間のコメント行
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

/// T16: parseBlockNodeImpl - 負数はシーケンスインジケータと誤認識されない
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- -5\n- -3.14", line, col, 0);
	assert(dst.getElement!int(0) == -5);
	assert(dst.getElement!double(1) == -3.14);
}

/// T16: parseBlockNodeImpl - 裸のスカラードキュメント
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

/// T16: parseBlockNodeImpl - キーの重複はパースエラーになる（Y12）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\na: 2", line, col, 0));
}

/// T16: parseBlockNodeImpl - 非スカラーキーは非対応としてエラーになる（Y9）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseBlockNodeImpl(dst, "a: 1\n[1,2]: value", line, col, 0));
}

/// T16: parseBlockNodeImpl - 明示キー（`?`）は非対応としてエラーになる（Y9）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "? a\n: 1", line, col, 0));
}

/// T16: parseBlockNodeImpl - quoted/flow値の直後の同一行の残存内容はエラーになる
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

/// T16: parseBlockNodeImpl - plainスカラーの折り畳みが行途中の埋め込みセパレータで
/// 終了した場合、残存内容はエラーになる（クラッシュせず明示的なエラーになることの回帰テスト）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\n    b: 2", line, col, 0));
}

/// T16: parseBlockNodeImpl - quoted値の後に続く想定外のインデント上昇はエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(
		builder.parseBlockNodeImpl(dst, "a: \"quoted\"\n    b: 2", line, col, 0));
}

/// T16: parseBlockNodeImpl - シーケンスとマッピングを同一インデントで混在させるとエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: 1\n- item", line, col, 0));
}

/// T16: parseBlockNodeImpl - インデントにタブ文字が混入するとエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a:\n\tb: 1", line, col, 0));
}

/// T17b: parseCommentTextImpl - `#`から行末までのコメント本文を読み取る
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

/// T17b: parseCommentTextImpl - 空コメント（`#`のみ）
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String text;
	auto consumed = builder.parseCommentTextImpl(text, "#\nnext", col);
	assert(consumed == 1);
	assert(cast(string)text == "");
}

/// T17b: leading comment(ルール1) - マッピングの最初のキーの前に書かれたコメントは
/// マッピング自身のleading commentになる
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

/// T17b: leading comment(ルール1) - 複数行のコメントは順序を保って蓄積される
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

/// T17b: leading comment(ルール1) - 空行を1つ以上挟んでも蓄積が継続する
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

/// T17b: leading comment(ルール1) - シーケンス項目の前のコメントはその項目のleading commentになる
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

/// T17b: leading comment(ルール1) - ネストしたコレクション自身の前のコメントは
/// そのコレクション自身のleading commentになる（先頭要素個別ではなく）
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

/// T17b: trailing comment(ルール2) - 値と同一行のコメントはその値のtrailing commentになる
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

/// T17b: leading commentとtrailing commentが同一ノードに共存する場合、
/// 配列内の順序はleadingが先・trailingが最後になる
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

/// T17b: flowコレクションの値全体に対する末尾コメントもtrailing commentになる
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

/// T17b: dangling comment(ルール3) - ファイル末尾のコメントは、それを含む
/// コレクション自身のtrailingCommentsになる
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

/// T17b: dangling comment(ルール3・4) - より浅いインデントのコメントは
/// 内側のコレクションのdangling commentにはならず、後続の実トークンの
/// leading commentとして正しく外側へ委譲される
/// （T17a調査結果: gopkg.in/yaml.v3 Issue #497 Case 1と同種の誤帰属を防ぐ回帰テスト）
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

/// T17b: dangling comment - 深さの異なる複数のdangling commentが
/// それぞれ正しい階層に帰属する
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

/// T17b: flowマッピング/flowシーケンス内のコメント(leading・dangling)
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

/// T17b(回帰テスト): plainスカラーの複数行折り畳みは、コメントのみの継続行では
/// 折り畳みを行わず、その手前でスカラーを終了させる
/// （修正前は`#`から始まる行の内容までスカラーの一部として誤って取り込んでいた）
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

/// T17b(回帰テスト): コメントを挟まない通常の複数行折り畳みは引き続き正しく動作する
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "key: this is\n  a folded value\nnext: 2", line, col, 0);
	assert(dst.getValue!string("key") == "this is a folded value");
	assert(dst.getValue!int("next") == 2);
}

/// T18: deepCopy - スカラー値は等しいがコレクションは独立したコピーになる
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

/// T18: parseAnchorNameImpl - 名前の終端判定（空白・flowインジケータ）
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

/// T18: parseAnchorNameImpl - flowコンテキストの区切り文字（`,`/`]`/`}`）で終端する
@safe unittest
{
	YamlBuilder builder;
	size_t col = 1;
	YamlBuilder.YamlValue.String name;
	auto consumed = builder.parseAnchorNameImpl(name, "x,rest", col);
	assert(consumed == 1);
	assert(cast(string)name == "x");
}

/// T18: 単純なスカラーへのアンカー・エイリアス解決
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

/// T18: コレクション全体へのエイリアスはdeepCopyにより独立したコピーになる
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

/// T18: 未定義アンカーの参照は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	assertThrown!YamlParseException(builder.parseBlockNodeImpl(dst, "a: *undefined", line, col, 0));
}

/// T18: 同名アンカーの再定義は後勝ちになる
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "a: &x 1\nb: &x 2\nc: *x", line, col, 0);
	assert(dst.asMapping["c"].get!int == 2);
}

/// T18: 同一アンカーへの複数のエイリアスはそれぞれ独立したコピーになる
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

/// T18: flowコレクション内でのアンカー・エイリアス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "{a: &x 1, b: *x}", line, col, 0);
	assert(dst.getValue!int("a") == 1);
	assert(dst.asMapping["b"].get!int == 1);
}

/// T18: マッピング値としてのネストしたコレクションへのアンカー
/// （アンカー自身が同一行の場合と独立行の場合の両方）
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

/// T18: シーケンス項目へのアンカー・エイリアス
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- &a 1\n- *a", line, col, 0);
	assert(dst.getElement!int(0) == 1);
	assert(dst.asSequence.value[1].get!int == 1);
}

/// T18(回帰テスト): アンカーの直後に続くplainスカラーの複数行折り畳みは、
/// アンカー自身の列位置ではなく、それを囲むエントリ自身のインデントを基準に
/// 判定される（修正前はアンカーの列位置を誤って基準にしていたため、
/// ネストした値が正しく認識できないバグがあった）
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- &a value\n  continued\n- other", line, col, 0);
	assert(dst.getElement!string(0) == "value continued");
	assert(dst.getElement!string(1) == "other");
}

/// T18(回帰テスト): エイリアスがさらにエイリアスを指す連鎖
/// （アンカーをエイリアスノード自体に付けた場合）も`dereference()`で
/// 最終的な実体まで再帰的に辿れる
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

/// T18: 空のアンカー名・エイリアス名は例外を送出する
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

/// T19: parseTagImpl - セカンダリタグハンドル（`!!str`等）は空白まで読み取る
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

/// T19: parseTagImpl - verbatim形式（`!<...>`）は閉じの`>`まで読み取る
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue.String tag;
	auto consumed = builder.parseTagImpl(tag, "!<tag:example.com,2000:app/mytype> rest", line, col);
	assert(consumed == 34);
	assert(cast(string)tag == "!<tag:example.com,2000:app/mytype>");
}

/// T19: parseTagImpl - verbatim形式で閉じの`>`が見つからない場合は例外を送出する
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue.String tag;
	assertThrown!YamlParseException(builder.parseTagImpl(tag, "!<unterminated", line, col));
}

/// T19: 明示タグは値の型解決に使わず、保持のみされる（Y6）
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

/// T19: プライマリタグ・裸の非specificタグ
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

/// T19: タグはネストしたコレクションにも付与できる
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

/// T19: タグとアンカーはどちらの順序でも組み合わせられる
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

/// T19: flowコンテキストでのタグ（スカラー・flowシーケンスへの付与）
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

/// T19: シーケンス項目それぞれへのタグ付与
@safe unittest
{
	YamlBuilder builder;
	size_t line = 1, col = 1;
	YamlBuilder.YamlValue dst;
	builder.parseBlockNodeImpl(dst, "- !!str 1\n- !!int 2", line, col, 0);
	assert(dst.asSequence.value[0].tagName.get == "!!str");
	assert(dst.asSequence.value[1].tagName.get == "!!int");
}

/// T1A: parse() - 単純なマッピング・シーケンス・裸のスカラー
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

/// T1A: parse() - 先頭のBOMは読み飛ばされる
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("\uFEFFa: 1\nb: 2");
	assert(result.type == YamlBuilder.YamlType.mapping);
	assert(result.getValue!int("a") == 1);
	assert(result.getValue!int("b") == 2);
}

/// T1A: parse() - ストリーム先頭以外のBOMはエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("a: 1\nb: \uFEFF2"));
}

/// T1A: parse() - 複数ドキュメント構文（行頭`---`/`...`）は明示的にエラーになる（Y7）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("---\na: 1"));
	assertThrown!YamlParseException(builder.parse("a: 1\n..."));
	assertThrown!YamlParseException(builder.parse("a: 1\n---\nb: 2"));
	assertThrown!YamlParseException(builder.parse("- 1\n- 2\n---\n- 3"));
}

/// T1A: parse() - `%`ディレクティブ行は明示的にエラーになる（Y7）
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("%YAML 1.2\n---\na: 1"));
}

/// T1A: parse() - 4個以上のダッシュはドキュメント区切りと誤認識されない
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("---- 1");
	assert(result.type == YamlBuilder.YamlType.string);
}

/// T1A: parse() - ルートノードの後に空行・コメントのみが続く場合は許容される
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("a: 1\n\n# comment\n");
	assert(result.getValue!int("a") == 1);
}

/// T1A: parse() - ルートノードの後に予期しない内容が続く場合はエラーになる
@safe unittest
{
	import std.exception : assertThrown;
	YamlBuilder builder;
	assertThrown!YamlParseException(builder.parse("a: 1\nrandom garbage"));
}

/// T1A: parse() - 空・空白のみ・コメントのみのドキュメントはnullになる
@safe unittest
{
	YamlBuilder builder;
	assert(builder.parse("").type == YamlBuilder.YamlType.nullfied);
	assert(builder.parse("   \n  \n").type == YamlBuilder.YamlType.nullfied);
	assert(builder.parse("# just a comment\n").type == YamlBuilder.YamlType.nullfied);
}

/// T1A: parse() - 行頭以外の`%`は通常のplainスカラー内容として扱われる
@safe unittest
{
	YamlBuilder builder;
	auto result = builder.parse("a: 50%value");
	assert(result.getValue!string("a") == "50%value");
}

/// T1A: parse() - コメント・アンカー・タグを組み合わせた総合テスト
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

/// T1A: parse() - 同一builderインスタンスを再利用しても、前回のparse()の
/// anchorTableが後続のparse()呼び出しに漏れ出さない
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

