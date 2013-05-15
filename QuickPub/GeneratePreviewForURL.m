#import <Cocoa/Cocoa.h>
#import <Objective-Zip/Objective-Zip.h>
#import "TBXML.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);
NSArray *manglePaths(NSData **xml);
NSString *mimeTypeForExtension(NSString *ext);

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // Open the ePub file, which is really just a zip
    ZipFile *epubZip = [ZipFile zipFileWithURL:(__bridge NSURL *)(url) mode:ZipFileModeUnzip error:nil];

    // Have a look at the container description to find the OPF file
    if ([epubZip locateFileInZip:@"META-INF/container.xml" error:nil])
    {
        ZipReadStream *containerStream = [epubZip readCurrentFileInZip:nil];
        NSData *containerData = [containerStream readDataOfLength:[epubZip getCurrentFileInZipInfo:nil].length error:nil];

        TBXML *containerXML = [[TBXML alloc] initWithXMLData:containerData error:nil];
        TBXMLElement *rootfiles = [TBXML childElementNamed:@"rootfiles" parentElement:[containerXML rootXMLElement]];
        TBXMLElement *rootfile = [TBXML childElementNamed:@"rootfile" parentElement:rootfiles];
        NSString *rootFileName = [TBXML valueOfAttributeNamed:@"full-path" forElement:rootfile];

        if ([epubZip locateFileInZip:rootFileName error:nil])
        {
            // Ok found OPF, lets open it
            ZipReadStream *opfStream = [epubZip readCurrentFileInZip:nil];
            NSData *opfData = [opfStream readDataOfLength:[epubZip getCurrentFileInZipInfo:nil].length error:nil];

            // Get guide, spine and manifest
            TBXML *opfXML = [[TBXML alloc] initWithXMLData:opfData error:nil];
            TBXMLElement *guide = [TBXML childElementNamed:@"guide" parentElement:[opfXML rootXMLElement]];
            TBXMLElement *spine = [TBXML childElementNamed:@"spine" parentElement:[opfXML rootXMLElement]];
            TBXMLElement *manifest = [TBXML childElementNamed:@"manifest" parentElement:[opfXML rootXMLElement]];

            NSString *previewFileName;

            // Try the cover entry in the guide first
            if (guide != NULL)
            {
                TBXMLElement *reference = [TBXML childElementNamed:@"reference" parentElement:guide];;
                do {
                    if ([[TBXML valueOfAttributeNamed:@"type" forElement:reference] isEqualToString:@"cover"])
                    {
                        previewFileName = [[rootFileName stringByDeletingLastPathComponent] stringByAppendingPathComponent:[TBXML valueOfAttributeNamed:@"href" forElement:reference]];
                    }
                    reference = reference->nextSibling;
                } while (reference != NULL);
            }

            if (previewFileName == nil)
            {
                // No cover found, get first chapter
                NSLog(@"No cover found in guide. Previewing first chapter");
                TBXMLElement *itemref = [TBXML childElementNamed:@"itemref" parentElement:spine];
                NSString *idref = [TBXML valueOfAttributeNamed:@"idref" forElement:itemref];
                TBXMLElement *item = [TBXML childElementNamed:@"item" parentElement:manifest];

                // Cross-reference first chapter from spine to manifest to get file name
                do {
                    if ([[TBXML valueOfAttributeNamed:@"id" forElement:item] isEqualToString:idref])
                    {
                        break;
                    }
                    else
                    {
                        item = item->nextSibling;
                    }
                } while (item != NULL);
                
                previewFileName = [[rootFileName stringByDeletingLastPathComponent] stringByAppendingPathComponent:[TBXML valueOfAttributeNamed:@"href" forElement:item]];
            }

            previewFileName = [previewFileName stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            NSLog(@"Previewing file %@", previewFileName);

            // Let's open the file to preview
            if ([epubZip locateFileInZip:previewFileName error:nil])
            {
                ZipReadStream *previewStream = [epubZip readCurrentFileInZip:nil];

                NSData *previewData = [previewStream readDataOfLength:[epubZip getCurrentFileInZipInfo:nil].length error:nil];

                // Mangle the XML to remove paths to referenced images etc. and get the names of the referenced files
                NSArray *referencedFiles = manglePaths(&previewData);

                // Build the props array to pass back to quicklookd
                NSMutableDictionary *props = [[NSMutableDictionary alloc] init];

                for (NSString *fileName in referencedFiles)
                {
                    NSString *zipPath = [previewFileName stringByDeletingLastPathComponent];

                    // Remove bla/../ components
                    for (NSString *pathComponent in [fileName pathComponents])
                    {
                        if ([pathComponent isEqualToString:@".."])
                        {
                            zipPath = [zipPath stringByDeletingLastPathComponent];
                        }
                        else
                        {
                            zipPath = [zipPath stringByAppendingPathComponent:pathComponent];
                        }
                    }

                    // Get the files from the zip
                    if ([epubZip locateFileInZip:zipPath error:nil])
                    {
                        ZipReadStream *fileStream = [epubZip readCurrentFileInZip:nil];
                        NSData *fileData = [fileStream readDataOfLength:[epubZip getCurrentFileInZipInfo:nil].length error:nil];

                        // Put file and it's mimetype metadata into props dict
                        NSMutableDictionary *fileProps = [[NSMutableDictionary alloc] init];
                        [fileProps setObject:mimeTypeForExtension([fileName pathExtension]) forKey:(__bridge NSString *)kQLPreviewPropertyMIMETypeKey];
                        [fileProps setObject:fileData forKey:(__bridge NSString *)kQLPreviewPropertyAttachmentDataKey];
                        [props setObject:[NSDictionary dictionaryWithObject:fileProps forKey:[fileName lastPathComponent]]
                                  forKey:(__bridge NSString *)kQLPreviewPropertyAttachmentsKey];
                    }
                }

                // Return the mangled XML and the referenced files
                QLPreviewRequestSetDataRepresentation(preview, (__bridge CFDataRef)(previewData), kUTTypeHTML, (__bridge CFDictionaryRef)(props));
            }
            else
            {
                NSLog(@"File '%@' not found in ePub.", previewFileName);
            }
        }
        else
        {
            NSLog(@"rootfile %@ not found in ePub.", rootFileName);
        }
    }
    else
    {
        NSLog(@"container.xml not found in ePub.");
    }

    return noErr;
}


// This function mangles all path references in the XML. It replaces the full
// path to a file with the string "cid:". This is required to let quicklookd
// know to fetch referenced images etc. from the props dict.
NSArray *manglePaths(NSData **xml)
{
    NSMutableArray *files = [[NSMutableArray alloc] init];
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:*xml options:0 error:nil];

    NSXMLNode *n = [doc rootElement];
    while ((n = [n nextNode]))
    {
        if ([n isKindOfClass:[NSXMLElement class]])
        {
            NSXMLElement *e = (NSXMLElement *)n;
            for (NSXMLNode *a in [e attributes])
            {
                if ([[a name] isEqualToString:@"src"]
                    | [[a name] isEqualToString:@"href"]
                    | [[a name] isEqualToString:@"xlink:href"])
                {
                    [files addObject:[a objectValue]];
                    [a setObjectValue:[@"cid:" stringByAppendingString:[[a objectValue] lastPathComponent]]];
                }
            }
        }
    }

    *xml = [doc XMLData];
    return files;
}

// This function returns the mime type for a given file extension. It asks the
// UTI system first, which unfortunately doesn't know everything. Add unknown
// types to the edge case list.
NSString *mimeTypeForExtension(NSString *ext)
{
    NSString* mimeType = @"";

    CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension,
                                                            (__bridge CFStringRef)ext, NULL);
    if( !UTI ) return nil;

    CFStringRef registeredType = UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType);
    if( !registeredType ) // check for edge case
    {
    	if( [ext isEqualToString:@"css"] )
    		mimeType = @"text/css";
    } else {
    	mimeType = (__bridge NSString *)(registeredType);
    }
    
    CFRelease(UTI);
    
    return mimeType;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}