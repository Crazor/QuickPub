QuickPub
========

A QuickLook generator for ePub cover pages

Compiling and installing
========================

For the impatient
-----------------
```
git clone https://github.com/Crazor/QuickPub.git
git clone https://github.com/aburgh/Objective-Zip.git
cd QuickPub
xcodebuild
qlmanage -r
```

For everyone else
-----------------

Clone this repository somewhere. Next to it, clone [aburgh/Objective-Zip](https://github.com/aburgh/Objective-Zip) which is referenced by the project file.

Open ```QuickPub.xcodeproj``` and hit Project -> Build. Or just run ```xcodebuild``` in a terminal. The build phase will copy ```QuickPub.qlgenerator``` to ```~/Library/QuickLook```.

Open a Terminal and run ```qlmanage -r``` to notify ```quicklookd``` of the changes.
