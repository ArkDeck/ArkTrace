fn main() {
    // Keep excess argv bounded before parsing, including the extra element
    // that proves the documented maximum was exceeded.
    let arguments = std::env::args_os()
        .skip(1)
        .take(arktrace_cli::arguments::MAXIMUM_ARGUMENTS + 1)
        .collect();
    std::process::exit(arktrace_cli::run(arguments));
}
