unused_args = false
std = "luajit"
self = false

globals = {
    "G_reader_settings",
}

read_globals = {
    "_ENV",
}

exclude_files = {
    "tests",
}

ignore = {
    "211/__*",
    "231/__",
    "631",
}
