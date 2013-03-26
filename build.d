immutable
	DEFAULT_SRCDIR   = ["voile"],
	DEFAULT_OUTPUT   = "voile",
	DEFAULT_DOC      = false,
	DEFAULT_TEST     = false,
	DEFAULT_LIB      = true,
	DEFAULT_DEBUG    = false,
	DEFAULT_JSON     = true,
	DEFAULT_RELEASE  = true,
	DEFAULT_WARNING  = true,
	DEFAULT_PROPERTY = true,
	DEFAULT_OBJDIR   = ".",
	DEFAULT_GUI      = false;

import std.exception, std.stdio, std.path, std.process, std.file, std.string,
	std.array, std.algorithm, std.getopt, std.conv;

version (BUILD_DUMMY)
{
	void main(){}
}
else:
void main(string[] args)
{
	string[] srcdir;
	Options opt;
	getopt(args,
		std.getopt.config.bundling,
		std.getopt.config.caseSensitive,
		"test|t", &opt.test,
		"lib|l", &opt.lib,
		"debug|d", &opt.dbg,
		"output|o", &opt.output,
		"object|O", &opt.obj,
		"gui|g", &opt.gui,
		"doc|D", &opt.doc,
		"json|j", &opt.json,
		"warn|w", &opt.warning,
		"property|prop|p", &opt.property,
		std.getopt.config.noBundling,
		"src|s", &srcdir);
	if (srcdir) opt.src = srcdir;
	
	if (args.length > 1)
		opt.options ~= args[1..$];
	
	int res;
	if (opt.doc)
	{
		res = makedoc(opt);
	}
	else
	{
		res = compile(opt);
		
		if (res == 0 && opt.test)
		{
			writeln("Begin testing...");
			stdout.flush();
			res = system(opt.output);
			writeln("Complete testing!");
			return;
		}
		
	}
	stdout.flush();
	enforce(res == 0,
		"Program abnormal terminate with return code: " ~ to!string(res));
	writeln("Complete!");
}

struct Options
{
	bool test     = DEFAULT_TEST;
	bool lib      = DEFAULT_LIB;
	bool dbg      = DEFAULT_DEBUG;
	bool gui      = DEFAULT_GUI;
	bool doc      = DEFAULT_DOC;
	bool json     = DEFAULT_JSON;
	bool warning  = DEFAULT_WARNING;
	bool property = DEFAULT_PROPERTY;
	string[] src  = DEFAULT_SRCDIR;
	string obj    = DEFAULT_OBJDIR;
	string output = DEFAULT_OUTPUT;
	string[] options;
}


int compile(Options opt)
{
	string[] opts;
	
	if (opt.test)
	{
		opts ~= ["-debug", "-g", "-unittest", "-I."];
		if (opt.warning)     opts ~= "-w";
		if (opt.property)    opts ~= "-property";
		if (opt.options)     opts ~= opt.options;
		if (opt.output)      opts ~= ["-of"~opt.output];
		foreach (s; opt.src) foreach (string ss; dirEntries(s, SpanMode.breadth))
		{
			if (!ss.isDir && ss.extension() == ".d") opts ~= ss;
		}
		if (opt.lib)         opts ~= ["-version=BUILD_DUMMY", "-run", "build.d"];
	}
	else
	{
		if (opt.lib)      opts ~= ["-lib", "-nofloat"];
		if (opt.dbg)      opts ~= ["-debug", "-g"];
		if (!opt.dbg)     opts ~= ["-release", "-inline", "-O", "-noboundscheck"];
		if (opt.gui)      opts ~= ["-L/exet:nt/su:windows:4.0"];
		if (opt.output)   opts ~= ["-of"~opt.output];
		if (opt.obj)      opts ~= ["-od"~opt.obj];
		if (opt.warning)  opts ~= ["-w"];
		if (opt.property) opts ~= ["-property"];
		if (opt.json)     opts ~= ["-X", "-Xf"~opt.output];
		if (opt.options)  opts ~= opt.options;
		foreach (s; opt.src) foreach (string ss; dirEntries(s, SpanMode.breadth))
		{
			if (!ss.isDir && ss.extension() == ".d") opts ~= ss;
		}
	}
	
	writeln("dmd " ~ std.string.join(opts, " "));
	
	return system("dmd " ~ std.string.join(opts, " "));
}


int makedoc(Options opt)
{
	string[] opts = ["-D", "-o-", "-c", "-Dddoc",
		"doc/candydoc/modules.ddoc",
		"doc/candydoc/candy.ddoc"];
	
	if (opt.dbg)     opts ~= ["-debug", "-g"];
	if (opt.warning) opts ~= ["-w"];
	if (!opt.dbg)    opts ~= ["-release", "-inline", "-O"];
	if (opt.options) opts ~= opt.options;
	
	string modules = "MODULES =\n";
	static struct FileData
	{
		string filename;
		string modname;
	}
	FileData[] docmods;
	foreach (s; opt.src) foreach (string ss; dirEntries(s, SpanMode.breadth))
	{
		if (ss.isDir) continue;
		if (ss.extension() != ".d" && ss.extension() != ".dd") continue;
		if (ss.baseName() == "index.dd")
		{
			docmods ~= FileData(ss, "index");
			modules ~= "	$(MODULE_FULL index)\n";
		}
		else
		{
			char[] tmp = ss.dup;
			foreach (ref char c; tmp)
			{
				if (c == '\\') c = '/';
			}
			if (countUntil(tmp, "/_") != -1) continue;
			foreach (ref char c; tmp)
			{
				if (c == '/') c = '.';
			}
			string modname = cast(immutable)baseName(tmp, tmp.extension());
			modules ~= "	$(MODULE_FULL " ~ modname ~ ")\n";
			docmods ~= FileData(ss, modname);
		}
	}
	std.file.write("doc/candydoc/modules.ddoc", modules);
	
	foreach (fd; docmods)
	{
		auto docopt = ["-Df" ~ fd.modname ~ ".html", fd.filename];
		writeln("dmd " ~ std.string.join(opts ~ docopt, " "));
		
		auto res = system("dmd " ~ std.string.join(opts ~ docopt, " "));
		if (res != 0) return res;
	}
	
	return 0;
}
