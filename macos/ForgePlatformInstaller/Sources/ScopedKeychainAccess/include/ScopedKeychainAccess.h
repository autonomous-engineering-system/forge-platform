#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
SecAccessRef FPIKeychainCreateRootOnlyAccess(void) CF_RETURNS_RETAINED;
SecAccessRef FPIKeychainCreateUIDReadAccess(uid_t uid) CF_RETURNS_RETAINED;
SecAccessRef FPIKeychainCreateUIDReadUpdate(SecAccessRef previous, uid_t uid) CF_RETURNS_RETAINED;
bool FPIKeychainHasUIDReadAccess(SecAccessRef access, SecAccessRef previous, uid_t uid);
bool FPIKeychainMarkAccessModified(SecAccessRef access);

// Declaration for source tests across Swift/Clang importers. The definition
// exists only in DEBUG C builds and is absent from release binaries.
SecAccessRef FPIKeychainCreateQualificationReadAccess(uid_t readerUID) CF_RETURNS_RETAINED;
