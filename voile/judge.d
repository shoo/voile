/*******************************************************************************
 * judgement モジュール
 * 
 * 複数の要素でチェックを行いたい場合に使用することのできる Judgement が利用可能
 * 
 * Date: September 08, 2011
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 * 
 */
module voile.judge;

import std.conv, std.traits;

private class MessageText(String)
{
	String _text;
	this(String str)
	{
		_text = str;
	}
	final override string toString() const
	{
		static if (is(String == string))
		{
			return _text;
		}
		else
		{
			return to!string(_text);
		}
	}
}


private MessageText!String msgtxt(String)(String str)
{
	return new MessageText!String(str);
}

/*******************************************************************************
 * 審判を含めて投げることのできる例外
 * 
 * 投げる際にJudgementオブジェクトを含めて投げることが可能です。
 *------------------------------------------------------------------------------
 * auto dJudge = new Judgement;
 * ...
 * if (dJudge.bad)
 * {
 *     throw new JudgementException(dJudge);
 * }
 *------------------------------------------------------------------------------
 */
class JudgementException: Exception
{
	/// Judgementオブジェクトへのアクセス
	Judgement judgement;
	/// コンストラクタ
	this(Judgement aJudge, string file = null, int line = 0)
	{
		super(aJudge.toString(), file, line);
		judgement = aJudge;
	}
	/// See_Also: Judgement.result()
	const(Object)[] results() const
	{
		return judgement.results;
	}
	/// See_Also: Judgement.opApply()
	int opApply(int delegate(ref Object) dg)
	{
		return judgement.opApply(dg);
	}
	/// ditto
	int opApply(int delegate(ref int, ref Object) dg)
	{
		return judgement.opApply(dg);
	}
}
/*******************************************************************************
 * 審判クラス
 * 
 * discuss() 関数の引数の結果が、存在するか否かで審判を下す。
 * 詳しくは discuss() 関数を参照。$(BR)
 * また、 discuss() 関数により審判を行ったあとは results() 関数で結果を得ること
 * が可能。 results() 関数は、 discuss() を行う際の引数に指定した文字列や Object
 * 実行する際に生じた例外などが含まれます。$(BR)
 * ヘルパ関数の judge() 関数と with 文と if 文、 ok ステータスを使うとスマートに
 * 見えるかも？
 * Example:
 * -----------------------------------------------------------------------------
 * void checkFunc()
 * {
 *     if (a.checked && b.checked)
 *     {
 *         throw new Exception("conflict switches 'a' and 'b'.");
 *     }
 * }
 * 
 * void func()
 * {
 *     with (judge(checkFunc))
 *     {
 *         if (ok)
 *         {
 *             status = "OK";
 *         }
 *         else
 *         {
 *             status = "NG [" ~ messages[0].toString ~ "]";
 *         }
 *     }
 * }
 * -----------------------------------------------------------------------------
 */
class Judgement
{
	private Object[] _results;
final:
	
	/***************************************************************************
	 * 審議
	 * 
	 * 引数を指定して審判を行います。$(BR)
	 * 下記の、引数の説明にあるリストの実行結果を判定し、
	 * $(UL
	 *     $(LI 引数                                                           )
	 *     $(LI 引数の実行結果                                                 )
	 *     $(LI 引数の実行に際して生じる例外                                   )
	 *     $(LI 引数のdelegateやfunctionの実行結果                             )
	 *     $(LI 引数のdelegateやfunctionの実行に際して生じる例外               )
	 * )
	 * を検出し、結果に加えます。$(BR)
	 * 実行の結果、nullを返すというのが良い結果であり、戻り値が発生する場合、
	 * 審判に否決したということになります。$(BR)
	 * 審判の結果は success や rejection またはそれらのすきな別名を使用して得る
	 * とが可能です。$(BR)
	 * ダイレクトに結果を得たい場合は results() 関数を呼び出すことで結果を出す
	 * 過程において生じた Object の配列を得ることが可能です。
	 * 
	 * Params:
	 *     args=下記リスト参照
	 *     $(UL
	 *         $(LI string                                                     )
	 *         $(LI Object                                                     )
	 *         $(LI string delegate()                                          )
	 *         $(LI Object delegate()                                          )
	 *         $(LI bool delegate()                                            )
	 *         $(LI void delegate()                                            )
	 *         $(LI string function()                                          )
	 *         $(LI Object function()                                          )
	 *         $(LI bool function()                                            )
	 *         $(LI void function()                                            )
	 *         $(LI 上記delegateおよびfunctionの実行結果                       )
	 *     )
	 *     複数の指定が可能です。$(BR)
	 *     引数のlazy属性によって、引数の順番通りの実行が保証されます。$(BR)
	 *     必ず1つ以上の引数を指定してください。
	 * Returns:
	 *     自分自身を返します
	 */
	typeof(this) discuss(T...)(lazy T args)
	{
		try
		{
			static if ( T.length == 0 )
			{
				static assert (0, "input anything arguments");
			}
			static if (isSomeString!(T[0]))
			{
				auto x = args[0]();
				if (x.length != 0)
				{
					_results ~= msgtxt(x);
				}
			}
			else static if (is(T[0] R == return ))
			{
				T[0] arg = args[0]();
				if (arg !is null && arg !is T[0].init)
				{
					static if (isSomeString!R)
					{
						auto x = arg();
						if (x.length != 0)
						{
							_results ~= msgtxt(x);
						}
					}
					else static if (is(R == void))
					{
						arg();
					}
					else static if(is(R == bool))
					{
						auto x = arg();
						if (x == false)
						{
							_results ~= msgtxt("failure");
						}
					}
					else static if(is(R : Object))
					{
						auto x = arg();
						if (x !is null
							&& x.toString !is null
							&& x.toString.length != 0)
						{
							_results ~= x;
						}
					}
					else
					{
						static assert(0,
							T[0].stringof ~ " is unsupported type.");
					}
				}
			}
			else static if ( is(T[0] : Object ) )
			{
				auto x = args[0]();
				if (x !is null
					&& x.toString() !is null
					&& x.toString().length != 0)
				{
					_results ~= x;
				}
			}
			else
			{
				static assert(0, T[0].stringof ~ " is unsupported type.");
			}
		}
		catch (Throwable ex)
		{
			if (auto o = cast(Object)ex)
			{
				_results ~= o;
			}
			else
			{
				_results ~= new Exception("Throwable", ex);
			}
		}
		
		static if(T.length > 1)
		{
			discuss(args[1..$]);
		}
		return this;
	}
	
	
	/***************************************************************************
	 * 合格しているか
	 */
	@property bool certified()
	{
		return _results.length == 0;
	}
	
	/// ditto
	alias certified ok;
	/// ditto
	alias certified good;
	/// ditto
	alias certified success;
	/// ditto
	alias certified succeeded;
	
	/***************************************************************************
	 * 否決されているか
	 */
	@property bool rejected()
	{
		return !certified();
	}
	/// ditto
	alias rejected ng;
	/// ditto
	alias rejected bad;
	/// ditto
	alias rejected failure;
	/// ditto
	alias rejected failed;
	
	/***************************************************************************
	 * 結果
	 * 
	 * 生じた Object のリストを返します。$(BR)
	 * 審判ではこの戻り値がnullであることが望ましい。
	 */
	@property const(Object)[] results() const
	{
		return _results;
	}
	
	
	/***************************************************************************
	 * foreach (d; judgement.result)と同義
	 */
	int opApply(int delegate(ref Object) dg)
	{
		int result = 0;
		foreach (ref Object e; _results)
		{
			result = dg(e);
			if (result) break;
		}
		return result;
	}
	
	
	/***************************************************************************
	 * foreach (i, d; judgement.result)と同義
	 */
	int opApply(int delegate(ref int, ref Object) dg)
	{
		int result = 0;
		foreach (int i, ref Object e; _results)
		{
			result = dg(i, e);
			if (result) break;
		}
		return result;
	}
	
	
	/***************************************************************************
	 * 文字列を返す
	 * Returns:
	 *     results のそれぞれのオブジェクトのtoStringで得られる文字列を改行でつ
	 *     ないだ文字列を返します。
	 */
	override string toString() const
	{
		string ret;
		foreach (o; results)
		{
			ret ~= o.toString() ~ '\n';
		}
		return cast(immutable)ret;
	}
	
	
	/***************************************************************************
	 * 例外を投げる
	 * Throws:
	 *     JudgementException=自身を含めたJudgementExceptionを投げる
	 */
	void throwIfFailure(bool doCopy = true)
	{
		if (bad) throw new JudgementException(this);
	}
}
/*******************************************************************************
 * Judgementクラスのヘルパ関数
 * 
 * インスタンスオブジェクトを生成し、審議し、返す。
 * Params:
 *     args=Judgement.discuss() の引数
 * Returns:
 *     審議した後の Judgement オブジェクト
 */
Judgement judge(T...)(lazy T args)
{
	auto temp = new Judgement;
	temp.discuss(args);
	return temp;
}


unittest
{
	
	static dstring func1()
	{
		return "1"d;
	}
	
	string x2 = "xx2";
	string func2()
	{
		return "2" ~ x2;
	}
	
	wstring func3()
	{
		x2 = "XXX";
		return "3"w;
	}
	
	static Object func4()
	{
		return new Exception("4");
	}
	
	static void func5()
	{
		throw new Exception("5");
	}
	
	static Object func6()
	{
		throw new Exception("6");
	}
	
	static Object func7()
	{
		return null;
	}
	
	
	
	
	with (judge(func1(), &func2, func3(), func4(), &func5, func6(), func7()))
	{
		if (ok)
		{
			// 今回はOKではない
			assert(0);
		}
		else
		{
			// func7だけは戻り値がnullなので結果はない
			assert(results.length == 6);
			if (auto r = results[0])
			{
				// 結果の参照
				assert(r.toString() == "1", to!string(results[0]));
			}
			else
			{
				assert(0);
			}
			if (auto r = results[1])
			{
				// 遅延評価によりfunc3より先にfunc2が呼ばれる
				assert(r.toString() == "2xx2");
			}
			else
			{
				assert(0);
			}
			if (auto r = cast(Exception)results[4])
			{
				// 例外をしっかり捕捉している
				assert(r.msg == "5", r.msg);
			}
			else
			{
				assert(0);
			}
		}
		if (! ng)
		{
			// 今回はNGである
			assert(0);
		}
	}
}

