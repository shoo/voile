/*******************************************************************************
 * 性能評価に関するモジュール
 * 
 * ベンチマークのヘルパクラスや、所定位置を通過した時間の記録、呼び出された回数
 * などを記録することのできるクラスを用意した。
 * 関数の実行にかかる時間を短縮し、スピードアップするのに役に立つかもしれない。
 * $(UL
 *     $(LI Benchmark)
 *     $(LI FootPrint)
 *     $(LI CallCounter)
 * ) 
 * Date: December 08, 2008
 * Authors:
 *     P.Knowledge, SHOO
 * License:
 *     NYSL ( http://www.kmonos.net/nysl/ )
 */

module voile.benchmark;

import std.exception, std.string, std.array, std.bigint, std.conv;
import std.datetime;
import std.datetime.stopwatch: StopWatch, AutoStart;
import core.thread;


/*******************************************************************************
 * 足跡を記録する
 * 
 * このクラスは、ファイルと行番号ごとに足跡をつけ、前回の足跡からどの程度の時間
 * が経過したかを記録し、時間がかかっている個所を特定するためのクラスです。
 *------------------------------------------------------------------------------
 *void main()
 *{
 *    scope fp = new FootPrint;
 *    fp.stamp(__FILE__,__LINE__);
 *    func1();
 *    fp.stamp(__FILE__,__LINE__);
 *    func2();
 *    fp.stamp(__FILE__,__LINE__);
 *    Stdout("Stamp infomations").newline;
 *    foreach (d; fp.result)
 *    {
 *        Stdout.formatln("{}({}): {} sec", d.file, d.line, d.time.interval);
 *    }
 *}
 *------------------------------------------------------------------------------
 */
/*******************************************************************************
 * For profiling.
 * 
 * It stamps the code footprints for searching bottlenecks.
 * When not enough to profile in -profile, this object is useful.
 * 
 */
struct FootPrintBenchmark
{
	/***************************************************************************
	 * 記録されるデータ
	 */
	static struct Data
	{
		/// 時間
		Duration time;
		
		
		/// 呼び出し元ファイル名
		string file;
		
		
		/// 呼び出し元行数
		uint line;
		
		
		/***********************************************************************
		 * 文字列表現
		 */
		string toString() const
		{
			return format("%s(%d): %s", file, line, time.total!"usecs" / 1.0e-6L);
		}
	}
	
	private StopWatch _sw;
	
	
	private Appender!(immutable(Data)[]) _datas;
	
	
	/***************************************************************************
	 * 自動測定コンストラクタ
	 * 
	 * AutoStartの値によって、自動的にストップウォッチ開始するか決まります。
	 */
	this(AutoStart as)
	{
		_sw = StopWatch(as);
	}
	
	
	/***************************************************************************
	 * ストップウォッチスタート
	 * 
	 * 初めてのスタートの場合、この時刻からの時間を測定して足跡に記録します。
	 * 一時停止からの復帰の場合、継続的に時間の測定を行います。
	 */
	void start()
	{
		_sw.start();
	}
	
	
	/***************************************************************************
	 * ストップウォッチストップ
	 * 
	 * 一時停止です。再び復帰する場合はstart()します
	 */
	void stop()
	{
		_sw.stop();
	}
	
	
	/***************************************************************************
	 * ストップウォッチリセット
	 */
	void reset()
	in (_datas.data.length == 0)
	{
		_sw.reset();
	}
	
	
	/***************************************************************************
	 * データをクリアします。
	 * 
	 * ストップウォッチの状態はそのままです。
	 * ストップウォッチをリセットする場合はresetをコールしてください
	 */
	void clear()
	{
		_datas = typeof(_datas)();
	}
	
	
	/***************************************************************************
	 * 足跡を記録します。
	 * 
	 * この関数を呼び出した時点での時間と、呼び出し元を記録してデータに追加しま
	 * す。
	 */
	void stamp(string f = __FILE__, uint l = __LINE__)
	{
		_datas.put(immutable(Data)(_sw.peek(), f, l));
	}
	
	
	/***************************************************************************
	 * 各データのそれぞれの呼び出し間隔を返します。
	 */
	immutable(real)[] intervals()
	{
		real[] ret;
		real last;
		foreach (i, d; _datas.data)
		{
			auto r = d.time.total!"usecs" / 1.0e-6L;
			import std.math;
			ret ~= !last.isNaN() ? r - last : r;
			last = r;
		}
		return assumeUnique(ret);
	}
	
	
	/***************************************************************************
	 * 記録されたデータそのものを返します
	 */
	immutable(Data)[] datas()
	{
		return _datas.data;
	}
	
	
	/***************************************************************************
	 * 記録されたデータそのものを返します
	 */
	immutable(Data)[] intervalDatas()
	{
		Data[] ret;
		auto alldatas = _datas.data;
		if (alldatas.length == 0)
			return null;
		Duration last = alldatas[0].time;
		foreach (i, d; alldatas)
		{
			Duration r = d.time;
			ret ~= Data(r - last, d.file, d.line);
			last = r;
		}
		return assumeUnique(ret);
	}
	
	alias opSlice = datas;
}


/*******************************************************************************
 * 呼び出しの情報を記録する
 * 
 * このクラスは呼び出した回数を記録する。呼び出された回数が多いほどその周囲は
 * 時間に気をつけるようにするとよい。
 */
class CallCounter
{
	/***************************************************************************
	 * 記録されるデータ
	 */
	public static immutable struct Data
	{
		/// ファイル名
		string file;
		/// 行番号
		uint line;
		/// 回数
		ulong count;
	}
	private ulong[uint][string] _data;
	
	
	/***************************************************************************
	 * 呼び出す
	 * 
	 * この関数を呼び出すことで、その場所の呼び出し回数カウントしていく。
	 */
	void call(string file = __FILE__, uint line =__LINE__)
	{
		if (auto temp1 = file in _data)
		{
			if (auto temp2 = line in *temp1)
			{
				++ *temp2;
			}
			else
			{
				(*temp1)[line] = 1;
			}
		}
		else
		{
			ulong[uint] temp;
			temp[line] = 1;
			_data[file] = temp;
		}
	}
	
	
	/***************************************************************************
	 * 結果を返す
	 * 
	 * このクラスは呼び出した回数を記録する。呼び出された回数が多いほどその周囲は
	 * 時間に気をつけるようにするとよい。
	 */
	immutable(Data)[] result()
	{
		immutable(Data)[] ret;
		foreach (temp1key, temp1value; _data)
		{
			foreach (temp2key, temp2value; temp1value)
			{
				ret ~= Data(temp1key, temp2key, temp2value);
			}
		}
		return ret;
	}
}


/*******************************************************************************
 * 
 */
struct ProfileData
{
	///
	Thread       thread;
	///
	string       file;
	///
	uint         line;
	///
	MonoTime     time;
	///
	MonoTime     duration;
}

/+
/*******************************************************************************
 * 
 */
shared class Profiler(OutputRange = Appender!(ProfileData[]))
{
public:
	
private:
	OutputRange datas;
	
	struct ScopeEndFinder
	{
	private:
		@disable this();
		@disable this(this);
		@disable @property Profiler init();
		size_t _idx;
		Profiler _p;
		this(Profiler p, size_t i)
		{
			_idx = i;
			_p   = p;
		}
	public:
		~this()
		{
			synchronized (_p)
			{
				auto data = (cast(OutputRange*)&_p.datas).data[_idx];
				data.duration = Clock.currAppTick() - data.time;
			}
		}
	}
	
public:
	
	/***************************************************************************
	 * 
	 */
	synchronized @property
	auto stamp(string file = __FILE__, uint line = __LINE__)()
	{
		thread = Thread.getThis();
		auto app = cast(OutputRange*)&datas;
		app.put(Data(name, file, line, Clock.currAppTick()));
		return ScopeEndFinder(this, app.data.length-1);
	}
	
	
	/***************************************************************************
	 * 
	 */
	synchronized immutable(ProfileData)[] data()
	{
		return (cast(OutputRange*)&datas).data.idup;
	}
}

private shared Profiler!() _sharedInstance;

shared static this()
{
	_sharedInstance = new Profiler!();
}


/*******************************************************************************
 * 
 */
shared Profiler!() profiler() nothrow @safe @property
{
	return _sharedInstance;
}

unittest
{
	auto prof = new Profiler;
	uint line;
	
	{
		auto stamp1 = prof.stamp("unittest"); line = __LINE__;
	}
	
	auto d = prof.data;
	assert(d.length == 1);
	assert(d[0].name == "unittest");
	assert(d[0].file == __FILE__);
	assert(d[0].line == line);
	
	{
		auto stamp1 = prof.stamp("unittest"); line = __LINE__;
	}
	
	d = prof.data;
	assert(d.length == 2);
	assert(d[1].name == "unittest");
	assert(d[1].file == __FILE__);
	assert(d[1].line == line);
	import std.stdio;
}

+/
