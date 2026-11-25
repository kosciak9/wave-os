# Joins the named pieces from this directory, in order, into one instructions text.
names: builtins.concatStringsSep "\n" (map (name: builtins.readFile (./. + "/${name}.md")) names)
