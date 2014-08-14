#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ffi/ffi.h>
#import <sys/mman.h>

// Wrapper closure called as a result of a message to `initWith..`
static void _ai_closure(ffi_cif * const aCif, id * const aoRet, void * const aArgs[], NSArray * const paramInfo);

static ffi_closure *_ai_ffi_allocClosure(void ** const codePtr);
static ffi_status _ai_ffi_prepareClosure(ffi_closure * const closure, ffi_cif * const cif,
                                         void (*fun)(ffi_cif*,void*,void**,void*),
                                         void * const user_data, void * const codeloc);
static ffi_type *_ai_encodingToFFIType(const char *aEncoding);
static ffi_type *_ai_scalarTypeToFFIType(const char * const aType);
static BOOL _ai_typeIsNumeric(const char * const aType);

@interface NSObject (AutomaticInitializers)
@end

@interface NSNumber (AutomaticInitializers)
+ (NSNumber *)ai_numberWithBytes:(const void *)aValue objCType:(const char *)aType;
@end

@implementation NSObject (AutomaticInitializers)
+ (void)load
{
    method_exchangeImplementations(class_getClassMethod([NSObject class], @selector(resolveClassMethod:)),
                                   class_getClassMethod([NSObject class], @selector(_ai_resolveClassMethod:)));
    method_exchangeImplementations(class_getClassMethod([NSObject class], @selector(resolveInstanceMethod:)),
                                   class_getClassMethod([NSObject class], @selector(_ai_resolveInstanceMethod:)));
}

+ (BOOL)_ai_resolveClassMethod:(SEL const)aSel
{
    NSString * const sel = NSStringFromSelector(aSel);
    NSRange const withRange = [sel rangeOfString:@"With"];
    if(withRange.location != NSNotFound && [sel hasSuffix:@":"]) {
        NSScanner * const scanner = [NSScanner scannerWithString:sel];
        scanner.scanLocation = NSMaxRange(withRange);

        NSString *encoding;
        IMP imp = [self _ai_impForSelector:aSel scanner:scanner typeEncoding:&encoding];
        if(imp) {
            class_addMethod(object_getClass(self), aSel, imp, [encoding UTF8String]);
            return YES;
        }
    }
    return [self _ai_resolveClassMethod:aSel];
}

+ (BOOL)_ai_resolveInstanceMethod:(SEL const)aSel
{
    NSString * const sel = NSStringFromSelector(aSel);
    if([sel hasPrefix:@"initWith"] && [sel hasSuffix:@":"]) {
        NSScanner * const scanner = [NSScanner scannerWithString:sel];
        scanner.scanLocation = 8;
        
        NSString *encoding;
        IMP imp = [self _ai_impForSelector:aSel scanner:scanner typeEncoding:&encoding];
        if(imp) {
            class_addMethod(self, aSel, imp, [encoding UTF8String]);
            return YES;
        }
    }
    return [self _ai_resolveInstanceMethod:aSel];
}

// aScanner must have its scan location at the first occurrence of a property within a initializing selector
+ (IMP)_ai_impForSelector:(SEL const)aSel scanner:(NSScanner * const)aScanner typeEncoding:(NSString **)aoEncoding
{
    NSParameterAssert(aSel && aScanner && aoEncoding);
    aScanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@":"];
    NSMutableArray  * const properties = [NSMutableArray new];
    NSMutableString * const typeEncoding = [@"@:" mutableCopy];

    NSString *propertyName;
    while([aScanner scanUpToString:@":" intoString:&propertyName]) {
        propertyName = [propertyName stringByReplacingCharactersInRange:(NSRange) {0, 1}
                                                             withString:[[propertyName substringToIndex:1] lowercaseString]];
        objc_property_t const property = class_getProperty(self, [propertyName UTF8String]);
        if(!property) {
            NSLog(@"No %@ found", propertyName);
            return NULL;
        }

        // Scan for the type encoding
        NSScanner * const attrScanner = [NSScanner scannerWithString:@(property_getAttributes(property))];
        [attrScanner scanUpToString:@"T" intoString:NULL];
        attrScanner.scanLocation += 1;
        NSString *encoding;
        if([attrScanner scanUpToString:@"," intoString:&encoding]) {
            [typeEncoding appendString:encoding];
            [properties addObject:@{ @"name": @(property_getName(property)),
                                     @"encoding": encoding,
                                     @"pointer": [NSValue valueWithPointer:property] }];
        } else {
            [NSException raise:NSInternalInconsistencyException
                        format:@"Unable to parse attributes for property %@", propertyName];
            return NULL;
        }
    }

    // Scan the property attributes for types
    ffi_type ** const parameterTypes = malloc(sizeof(void*) * ([properties count] + 2));
    parameterTypes[0] = parameterTypes[1] = &ffi_type_pointer;

    for(NSUInteger i = 0; i < [properties count]; ++i) {
        parameterTypes[i+2] = _ai_encodingToFFIType([properties[i][@"encoding"] UTF8String]);
    }

    // Create the IMP
    void *imp;
    ffi_closure *closure = _ai_ffi_allocClosure(&imp);
    if(!closure) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Failed to allocate closure for %@", NSStringFromSelector(aSel)];
        return NULL;
    }

    ffi_cif * const cif = malloc(sizeof(ffi_cif));
    if(ffi_prep_cif(cif, FFI_DEFAULT_ABI,
                    (unsigned int)[properties count] + 2,
                    &ffi_type_pointer,
                    parameterTypes) == FFI_OK
       && _ai_ffi_prepareClosure(closure, cif,
                                 (void (*)(ffi_cif*,void*,void**,void*))_ai_closure,
                                 (__bridge_retained void*)properties,
                                 imp) == FFI_OK)
    {
        *aoEncoding = typeEncoding;
        return imp;
    }
    else {
        free(cif);
        [NSException raise:NSInternalInconsistencyException
                    format:@"Failed to perpare closure for %@", NSStringFromSelector(aSel)];
        return NULL;
    }
}

@end

void _ai_closure(ffi_cif * const aCif, id * const aoRet, void * const aArgs[], NSArray * const properties)
{
    id object = *(__strong id *)aArgs[0];
    if(class_isMetaClass(object_getClass(object)))
        object = [[object alloc] init];
    else
        object = [object init];

    for(unsigned int i = 2; i < aCif->nargs; ++i) {
        NSDictionary * const property = properties[i-2];
        const char * const encoding = [property[@"encoding"] UTF8String];
        id const box = *encoding == _C_ID
                     ? *(__strong id *)aArgs[i]
                     : _ai_typeIsNumeric(encoding)
                     ? [NSNumber ai_numberWithBytes:aArgs[i] objCType:[property[@"encoding"] UTF8String]]
                     : [NSValue valueWithBytes:aArgs[i] objCType:[property[@"encoding"] UTF8String]];
        [object setValue:box forKey:property[@"name"]];
    }
    *aoRet = object;
}


#pragma mark - FFI & Type wrangling

static ffi_closure *_ai_ffi_allocClosure(void ** const codePtr)
{
    ffi_closure *closure = (ffi_closure *)mmap(NULL, sizeof(ffi_closure), PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if(closure == (void *)-1) {
        perror("mmap");
        return NULL;
    }
    *codePtr = closure;
    return closure;
}

static ffi_status _ai_ffi_prepareClosure(ffi_closure * const closure, ffi_cif * const cif,
                                         void (*fun)(ffi_cif*,void*,void**,void*),
                                         void * const user_data, void * const codeloc)
{
    ffi_status status = ffi_prep_closure(closure, cif, fun, user_data);
    if(status != FFI_OK)
        return status;
    if(mprotect(closure, sizeof(closure), PROT_READ | PROT_EXEC) == -1)
        return (ffi_status)1;
    return FFI_OK;
}

BOOL _ai_type_is_scalar(const char * const aType)
{
    return !(*aType == _C_STRUCT_B || *aType == _C_UNION_B || *aType == _C_ARY_B);
}

ffi_type *_ai_encodingToFFIType(const char *aEncoding)
{
    if(_ai_type_is_scalar(aEncoding))
        return _ai_scalarTypeToFFIType(aEncoding);
    else if(*aEncoding == _C_STRUCT_B || *aEncoding ==_C_ARY_B) {
        BOOL const isArray = *aEncoding ==_C_ARY_B;

        ffi_type * const type =  malloc(sizeof(ffi_type));
        type->type = FFI_TYPE_STRUCT;
        type->size = type->alignment= 0;
        
        int numFields = 0;
        const char *fieldEncoding;
        if(isArray) {
            ++aEncoding; // Skip past the '['
            assert(isdigit(*aEncoding));
            numFields = atoi(aEncoding);
            // Move on to the enclosed type
            while(isdigit(*aEncoding)) ++aEncoding;
            fieldEncoding = aEncoding;
        } else { // Is struct
            fieldEncoding = strstr(aEncoding, "=") + 1;
            if(*fieldEncoding != _C_STRUCT_E) {
                const char *currField = fieldEncoding;
                do {
                    ++numFields;
                } while((currField = NSGetSizeAndAlignment(currField, NULL, NULL)) && *currField != _C_STRUCT_E);
            }
        }
        type->elements = (ffi_type **)malloc(sizeof(ffi_type*) * numFields + 1);
        
        if(isArray) {
            ffi_type *fieldType = _ai_encodingToFFIType(fieldEncoding);
            assert(fieldType);
            for(int i = 0; i < numFields; i++) {
                type->elements[i] = fieldType;
            }
        } else {
            for(int i = 0; i < numFields; i++) {
                ffi_type *fieldType = _ai_encodingToFFIType(fieldEncoding);
                assert(fieldType);
                type->elements[i] = fieldType;
                fieldEncoding = NSGetSizeAndAlignment(fieldEncoding, NULL, NULL);
            }
        }
        
        type->elements[numFields] = NULL;
        return type;
    }    
    else if(*aEncoding == _C_UNION_B) {
        // For unions we just return the ffi type for the first element in the union
        // TODO: this should use the largest type 
        const char *fieldEncoding = strstr(aEncoding, "=") + 1;
        return _ai_encodingToFFIType(fieldEncoding);
    } else {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unhandled type encoding %s", aEncoding];
        return NULL;
    }
}

BOOL _ai_typeIsNumeric(const char * const aType)
{
    char const type = *aType;
    return type == _C_DBL  || type == _C_FLT     || type == _C_INT
        || type == _C_SHT  || type == _C_CHR     || type == _C_BOOL
        || type == _C_LNG  || type == _C_LNG_LNG || type == _C_UINT
        || type == _C_USHT || type == _C_UCHR    || type == _C_ULNG
        || type == _C_ULNG_LNG;
}

ffi_type *_ai_scalarTypeToFFIType(const char * const aType)
{
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:
        case _C_SEL:
        case _C_PTR:
        case _C_CHARPTR:  return &ffi_type_pointer;
        case _C_DBL:      return &ffi_type_double;
        case _C_FLT:      return &ffi_type_float;
        case _C_INT:      return &ffi_type_sint;
        case _C_SHT:      return &ffi_type_sshort;
        case _C_CHR:      return &ffi_type_sint8;
        case _C_BOOL:     return &ffi_type_uchar;
        case _C_LNG:      return &ffi_type_slong;
        case _C_LNG_LNG:  return &ffi_type_sint64;
        case _C_UINT:     return &ffi_type_uint;
        case _C_USHT:     return &ffi_type_ushort;
        case _C_UCHR:     return &ffi_type_uchar;
        case _C_ULNG:     return &ffi_type_ulong;
        case _C_ULNG_LNG: return &ffi_type_uint64;
        case _C_VOID:     return &ffi_type_void;
        default:
            [NSException raise:NSGenericException
                        format:@"Unsupported scalar type %c!", *aType];
            return NULL;
    }
}

@implementation NSNumber (AutoInitializers)
+ (NSNumber *)ai_numberWithBytes:(const void * const )aValue
                        objCType:(const char * const )aType
{
    NSParameterAssert(aType && aValue);
    switch(*aType) {
        case _C_DBL:      return @(*(double *)aValue);
        case _C_FLT:      return @(*(float *)aValue);
        case _C_INT:      return @(*(int *)aValue);
        case _C_SHT:      return @(*(short *)aValue);
        case _C_CHR:      return @(*(char *)aValue);
        case _C_BOOL:     return @(*(BOOL *)aValue);
        case _C_LNG:      return @(*(long *)aValue);
        case _C_LNG_LNG:  return @(*(long long *)aValue);
        case _C_UINT:     return @(*(unsigned int *)aValue);
        case _C_USHT:     return @(*(unsigned short *)aValue);
        case _C_UCHR:     return @(*(unsigned char *)aValue);
        case _C_ULNG:     return @(*(unsigned long *)aValue);
        case _C_ULNG_LNG: return @(*(unsigned long long *)aValue);
        default:
            [NSException raise:NSGenericException
                        format:@"Tried to create NSNumber from non-numeric type %c!", *aType];
            return nil;
    }
}
@end
