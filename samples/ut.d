module samples.ut;

private extern (C) void dmd_coverDestPath( string pathname );
private extern (C) void dmd_coverSetMerge( bool flag );
shared static this()
{
	import std.file;
	import core.stdc.stdio;
	setvbuf(stdout, null, _IONBF, 0);
	if (!"cov".exists)
	{
		mkdir("cov");
	}
	else
	{
		dmd_coverSetMerge(true);
	}
	dmd_coverDestPath("cov");
}
