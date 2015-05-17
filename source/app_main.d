/// Written in the D programming language.
/// Date: 2014-2015, Joakim Brännström
/// License: GPL
/// Author: Joakim Brännström (joakim.brannstrom@gmx.com)
///
/// This program is free software; you can redistribute it and/or modify
/// it under the terms of the GNU General Public License as published by
/// the Free Software Foundation; either version 2 of the License, or
/// (at your option) any later version.
///
/// This program is distributed in the hope that it will be useful,
/// but WITHOUT ANY WARRANTY; without even the implied warranty of
/// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
/// GNU General Public License for more details.
///
/// You should have received a copy of the GNU General Public License
/// along with this program; if not, write to the Free Software
/// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
module app_main;

import std.conv;
import std.exception;
import std.stdio;
import std.string;
import std.typecons;

import file = std.file;
import logger = std.experimental.logger;

import docopt;
import argvalue; // from docopt
import tested;
import dsrcgen.cpp;

static string doc = "
usage:
  gen-test-double stub [options] FILE [--] [CFLAGS...]
  gen-test-double mock [options] FILE

arguments:
 FILE           C++ header to generate stubs from
 CFLAGS         Compiler flags.

options:
 -h, --help         show this
 -d=<dest>          destination of generated files [default: .]
 --debug            turn on debug output for tracing of generator flow
 --file-scope=<l>   limit generation to input FILE or process everything [default: single]
                    Allowed values are: all, single
 --func-scope=<l>   limit generation to kind of functions [default: virtual]
                    Allowed values are: all, virtual
";

enum ExitStatusType {
    Ok,
    Errors
}

enum FileScopeType {
    Invalid,
    All,
    Single
}

enum FuncScopeType {
    Invalid,
    All,
    Virtual
}

auto stringToFileScopeType(string s) {
    switch (s) with (FileScopeType) {
    case "all":
        return All;
    case "single":
        return Single;
    default:
        return Invalid;
    }
}

auto stringToFuncScopeType(string s) {
    switch (s) with (FuncScopeType) {
    case "all":
        return All;
    case "virtual":
        return Virtual;
    default:
        return Invalid;
    }
}

class SimpleLogger : logger.Logger {
    int line = -1;
    string file = null;
    string func = null;
    string prettyFunc = null;
    string msg = null;
    logger.LogLevel lvl;

    this(const logger.LogLevel lv = logger.LogLevel.info) {
        super(lv);
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        this.line = payload.line;
        this.file = payload.file;
        this.func = payload.funcName;
        this.prettyFunc = payload.prettyFuncName;
        this.lvl = payload.logLevel;
        this.msg = payload.msg;

        stderr.writefln("%s: %s", text(this.lvl), this.msg);
    }
}

shared static this() {
    version (unittest) {
        import core.runtime;

        Runtime.moduleUnitTester = () => true;
        assert(runUnitTests!app_main(new ConsoleTestResultWriter), "Unit tests failed.");
    }
}

auto try_open_file(string filename, string mode) @trusted nothrow {
    Unique!File rval;
    try {
        rval = Unique!File(new File(filename, mode));
    }
    catch (Exception ex) {
    }
    if (rval.isEmpty) {
        try {
            logger.errorf("Unable to read/write file '%s'", filename);
        }
        catch (Exception ex) {
        }
    }

    return rval;
}

ExitStatusType gen_stub(const string infile, const string outdir,
    const ref string[] cflags, FileScopeType file_scope, FuncScopeType func_scope) {
    import std.exception;
    import std.path : baseName, buildPath, stripExtension;
    import generator;

    auto hdr_ext = ".hpp";
    auto impl_ext = ".cpp";
    auto prefix = StubPrefix("Stub");

    auto base_filename = infile.baseName.stripExtension;
    HdrFilename hdr_filename = HdrFilename(base_filename ~ hdr_ext);
    HdrFilename stub_hdr_filename = HdrFilename((cast(string) prefix).toLower ~ "_" ~ hdr_filename);
    string hdr_out_filename = buildPath(outdir, cast(string) stub_hdr_filename);
    string impl_out_filename = buildPath(outdir,
        (cast(string) prefix).toLower ~ "_" ~ base_filename ~ impl_ext);

    if (!file.exists(infile)) {
        logger.errorf("File '%s' do not exist", infile);
        return ExitStatusType.Errors;
    }

    logger.infof("Generating stub from '%s'", infile);

    auto file_ctx = new Context(infile, cflags);
    file_ctx.logDiagnostic;
    if (file_ctx.hasParseErrors)
        return ExitStatusType.Errors;

    auto ctx = new StubContext(prefix, HdrFilename(infile.baseName));
    if (file_scope == FileScopeType.Single)
        ctx.onlyTranslateFile(HdrFilename(infile));
    if (func_scope == FuncScopeType.Virtual)
        ctx.onlyStubVirtual;
    ctx.translate(file_ctx.cursor);

    auto outfile_hdr = try_open_file(hdr_out_filename, "w");
    if (outfile_hdr.isEmpty) {
        return ExitStatusType.Errors;
    }
    scope (exit)
        outfile_hdr.close();

    auto outfile_impl = try_open_file(impl_out_filename, "w");
    if (outfile_impl.isEmpty) {
        return ExitStatusType.Errors;
    }
    scope (exit)
        outfile_impl.close();

    try {
        outfile_hdr.write(ctx.output_header(stub_hdr_filename));
        outfile_impl.write(ctx.output_impl(stub_hdr_filename));
    }
    catch (ErrnoException ex) {
        logger.trace(text(ex));
        return ExitStatusType.Errors;
    }

    return ExitStatusType.Ok;
}

void prepare_env(ref ArgValue[string] parsed) {
    import std.experimental.logger.core : sharedLog;

    try {
        if (parsed["--debug"].isTrue) {
            logger.globalLogLevel(logger.LogLevel.all);
        }
        else {
            logger.globalLogLevel(logger.LogLevel.info);
            auto simple_logger = new SimpleLogger();
            logger.sharedLog(simple_logger);
        }
    }
    catch (Exception ex) {
        collectException(logger.error("Failed to configure logging level"));
        throw ex;
    }
}

ExitStatusType do_test_double(ref ArgValue[string] parsed) {
    import std.algorithm : among;

    ExitStatusType exit_status = ExitStatusType.Errors;
    FileScopeType file_scope = stringToFileScopeType(parsed["--file-scope"].toString);
    FuncScopeType func_scope = stringToFuncScopeType(parsed["--func-scope"].toString);

    string[] cflags;
    if (parsed["--"].isTrue) {
        cflags = parsed["CFLAGS"].asList;
    }

    if (file_scope == FileScopeType.Invalid) {
        logger.error("Usage error: --file-scope must be either of: [all, single]");
        writeln(doc);
    }

    if (func_scope == FileScopeType.Invalid) {
        logger.error("Usage error: --func-scope must be either of: [all, virtual]");
        writeln(doc);
    }

    else if (parsed["stub"].isTrue) {
        exit_status = gen_stub(parsed["FILE"].toString, parsed["-d"].toString,
            cflags, file_scope, func_scope);
    }
    else if (parsed["mock"].isTrue) {
        logger.error("Mock generation not implemented yet");
    }
    else {
        logger.error("Usage error");
        writeln(doc);
    }

    return exit_status;
}

int rmain(string[] args) nothrow {
    import std.array : join;

    string errmsg, tracemsg;
    ExitStatusType exit_status = ExitStatusType.Errors;
    bool help = true;
    bool optionsFirst = false;
    auto version_ = "gen-test-double v0.1";

    try {
        auto parsed = docopt.docopt(doc, args[1 .. $], help, version_, optionsFirst);
        prepare_env(parsed);
        logger.trace(to!string(args));
        logger.trace(join(args, " "));
        logger.trace(prettyPrintArgs(parsed));

        exit_status = do_test_double(parsed);
    }
    catch (Exception ex) {
        collectException(logger.trace(text(ex)));
        exit_status = ExitStatusType.Errors;
    }

    return cast(typeof(return)) exit_status;
}
