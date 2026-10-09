// One exact effective UID plus root may decrypt. Updates preserve the owner.
// No any-user, group, application wildcard, or delegated authorization exists.
#include "ScopedKeychainAccess.h"
#include <Security/cssmapple.h>
#include <string.h>
#include <stdlib.h>
static SecAccessRef createRootOwnedReader(uid_t uid) {
    CSSM_ACL_PROCESS_SUBJECT_SELECTOR ownerSelector = {CSSM_ACL_PROCESS_SELECTOR_CURRENT_VERSION, CSSM_ACL_MATCH_UID | CSSM_ACL_MATCH_HONOR_ROOT, 0, 0};
    CSSM_ACL_PROCESS_SUBJECT_SELECTOR readerSelector = {CSSM_ACL_PROCESS_SELECTOR_CURRENT_VERSION, CSSM_ACL_MATCH_UID | CSSM_ACL_MATCH_HONOR_ROOT, uid, 0};
    CSSM_LIST_ELEMENT ownerData = {0}, ownerType = {0}, readerData = {0}, readerType = {0};
    ownerData.ElementType = CSSM_LIST_ELEMENT_DATUM;
    ownerData.Element.Word.Length = sizeof(ownerSelector);
    ownerData.Element.Word.Data = (uint8*)&ownerSelector;
    ownerType.ElementType = CSSM_LIST_ELEMENT_WORDID; ownerType.WordID = CSSM_ACL_SUBJECT_TYPE_PROCESS;
    ownerType.NextElement = &ownerData;
    readerData.ElementType = CSSM_LIST_ELEMENT_DATUM;
    readerData.Element.Word.Length = sizeof(readerSelector);
    readerData.Element.Word.Data = (uint8*)&readerSelector;
    readerType.ElementType = CSSM_LIST_ELEMENT_WORDID; readerType.WordID = CSSM_ACL_SUBJECT_TYPE_PROCESS;
    readerType.NextElement = &readerData;
    CSSM_ACL_OWNER_PROTOTYPE owner = {0}; owner.TypedSubject.ListType = CSSM_LIST_TYPE_SEXPR;
    owner.TypedSubject.Head = &ownerType; owner.TypedSubject.Tail = &ownerData;
    CSSM_ACL_AUTHORIZATION_TAG authorization = CSSM_ACL_AUTHORIZATION_DECRYPT;
    CSSM_ACL_ENTRY_INFO entry = {0}; entry.EntryPublicInfo.TypedSubject.ListType = CSSM_LIST_TYPE_SEXPR;
    entry.EntryPublicInfo.TypedSubject.Head = &readerType; entry.EntryPublicInfo.TypedSubject.Tail = &readerData;
    entry.EntryPublicInfo.Authorization.NumberOfAuthTags = 1; entry.EntryPublicInfo.Authorization.AuthTags = &authorization;
    SecAccessRef result = NULL;
    return SecAccessCreateFromOwnerAndACL(&owner, 1, &entry, &result) == errSecSuccess ? result : NULL;
}

SecAccessRef FPIKeychainCreateRootOnlyAccess(void) {
    return createRootOwnedReader(0);
}
SecAccessRef FPIKeychainCreateUIDReadAccess(uid_t uid) {
    return uid > 0 ? createRootOwnedReader(uid) : NULL;
}

static bool hasRight(const CSSM_ACL_ENTRY_INFO *entry, CSSM_ACL_AUTHORIZATION_TAG tag) {
    for (uint32 i = 0; i < entry->EntryPublicInfo.Authorization.NumberOfAuthTags; ++i)
        if (entry->EntryPublicInfo.Authorization.AuthTags[i] == tag) return true;
    return false;
}

static bool processSubject(const CSSM_LIST *list, uid_t uid) {
    const CSSM_LIST_ELEMENT *type = list->Head;
    const CSSM_LIST_ELEMENT *data = type ? type->NextElement : NULL;
    if (!type || type->ElementType != CSSM_LIST_ELEMENT_WORDID || type->WordID != CSSM_ACL_SUBJECT_TYPE_PROCESS
        || !data || data->ElementType != CSSM_LIST_ELEMENT_DATUM || data->NextElement
        || data->Element.Word.Length != sizeof(CSSM_ACL_PROCESS_SUBJECT_SELECTOR)) return false;
    CSSM_ACL_PROCESS_SUBJECT_SELECTOR selector;
    memcpy(&selector, data->Element.Word.Data, sizeof(selector));
    return selector.version == CSSM_ACL_PROCESS_SELECTOR_CURRENT_VERSION
        && selector.mask == (CSSM_ACL_MATCH_UID | CSSM_ACL_MATCH_HONOR_ROOT)
        && selector.uid == uid && selector.gid == 0;
}

static bool sameList(const CSSM_LIST *a, const CSSM_LIST *b, unsigned depth) {
    if (depth > 16 || a->ListType != b->ListType) return false;
    const CSSM_LIST_ELEMENT *x = a->Head, *y = b->Head;
    unsigned count = 0;
    while (x && y) {
        if (++count > 128 || x->ElementType != y->ElementType || x->WordID != y->WordID) return false;
        switch (x->ElementType) {
        case CSSM_LIST_ELEMENT_WORDID: break;
        case CSSM_LIST_ELEMENT_DATUM:
            if (x->Element.Word.Length != y->Element.Word.Length || x->Element.Word.Length > 1024 * 1024
                || memcmp(x->Element.Word.Data, y->Element.Word.Data, x->Element.Word.Length)) return false;
            break;
        case CSSM_LIST_ELEMENT_SUBLIST:
            if (!sameList(&x->Element.Sublist, &y->Element.Sublist, depth + 1)) return false;
            break;
        default: return false;
        }
        x = x->NextElement; y = y->NextElement;
    }
    return x == NULL && y == NULL;
}

bool FPIKeychainHasUIDReadAccess(SecAccessRef access, SecAccessRef previous, uid_t uid) {
    CSSM_ACL_OWNER_PROTOTYPE_PTR owner = NULL; CSSM_ACL_ENTRY_INFO_PTR entries = NULL; uint32 count = 0;
    CSSM_ACL_OWNER_PROTOTYPE_PTR priorOwner = NULL; CSSM_ACL_ENTRY_INFO_PTR priorEntries = NULL; uint32 priorCount = 0;
    if (!access || uid == 0 || SecAccessGetOwnerAndACL(access, &owner, &count, &entries) != errSecSuccess
        || SecAccessGetOwnerAndACL(previous, &priorOwner, &priorCount, &priorEntries) != errSecSuccess
        || !owner || !priorOwner || owner->Delegate != priorOwner->Delegate
        || !sameList(&owner->TypedSubject, &priorOwner->TypedSubject, 0) || count > 64) return false;
    uint32 readers = 0;
    for (uint32 i = 0; i < count; ++i) {
        if (hasRight(&entries[i], CSSM_ACL_AUTHORIZATION_ANY)) return false;
        if (hasRight(&entries[i], CSSM_ACL_AUTHORIZATION_DECRYPT)) {
            if (entries[i].EntryPublicInfo.Delegate
                || entries[i].EntryPublicInfo.Authorization.NumberOfAuthTags != 1
                || !processSubject(&entries[i].EntryPublicInfo.TypedSubject, uid)) return false;
            ++readers;
        }
    }
    return readers == 1;
}

bool FPIKeychainMarkAccessModified(SecAccessRef access) {
    CFArrayRef list = NULL;
    if (SecAccessCopyACLList(access, &list) != errSecSuccess || !list) return false;
    bool okay = true;
    for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
        SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(list, i);
        CFArrayRef tags = SecACLCopyAuthorizations(acl);
        if (!tags) { okay = false; continue; }
        bool owner = CFArrayContainsValue(tags, CFRangeMake(0, CFArrayGetCount(tags)), kSecACLAuthorizationChangeACL);
        if (!owner && SecACLUpdateAuthorizations(acl, tags) != errSecSuccess) okay = false;
        if (tags) CFRelease(tags);
    }
    CFRelease(list); return okay;
}

SecAccessRef FPIKeychainCreateUIDReadUpdate(SecAccessRef previous, uid_t uid) {
    CSSM_ACL_OWNER_PROTOTYPE_PTR oldOwner = NULL; CSSM_ACL_ENTRY_INFO_PTR entries = NULL; uint32 count = 0;
    if (uid == 0 || SecAccessGetOwnerAndACL(previous, &oldOwner, &count, &entries) != errSecSuccess
        || count == 0 || count > 64) return NULL;
    uint32 readers = 0, selected = 0;
    for (uint32 i = 0; i < count; ++i) {
        if (hasRight(&entries[i], CSSM_ACL_AUTHORIZATION_ANY)) return NULL;
        if (hasRight(&entries[i], CSSM_ACL_AUTHORIZATION_DECRYPT)) { ++readers; selected = i; }
    }
    if (readers != 1) return NULL;
    SecAccessRef template = FPIKeychainCreateUIDReadAccess(uid);
    CSSM_ACL_OWNER_PROTOTYPE_PTR owner = NULL; CSSM_ACL_ENTRY_INFO_PTR reader = NULL; uint32 readerCount = 0;
    if (!template || SecAccessGetOwnerAndACL(template, &owner, &readerCount, &reader) != errSecSuccess
        || readerCount != 1) { if (template) CFRelease(template); return NULL; }
    // Keep the original entry handle so an update addresses the existing ACL.
    // Preserve unrelated OS integrity/partition entries and their handles.
    CSSM_ACL_HANDLE handle = entries[selected].EntryHandle;
    entries[selected] = reader[0]; entries[selected].EntryHandle = handle;
    SecAccessRef result = NULL;
    // Preserve the established item's owner byte for byte. Public ACL APIs
    // cannot edit authorizations on the pseudo owner entry.
    OSStatus status = SecAccessCreateFromOwnerAndACL(oldOwner, count, entries, &result);
    CFRelease(template);
    if (status != errSecSuccess || !result) return NULL;
    CFArrayRef list = NULL;
    if (SecAccessCopyACLList(result, &list) != errSecSuccess || !list) { CFRelease(result); return NULL; }
    bool okay = true;
    for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
        SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(list, i);
        CFArrayRef tags = SecACLCopyAuthorizations(acl);
        if (!tags) { okay = false; continue; }
        bool change = CFArrayContainsValue(tags, CFRangeMake(0, CFArrayGetCount(tags)), kSecACLAuthorizationDecrypt);
        // CSSM-derived ACLs start as unchanged. Explicitly mark these two
        // reader entry modified through the public API before SetAccess(update).
        if (change && SecACLUpdateAuthorizations(acl, tags) != errSecSuccess) okay = false;
        CFRelease(tags);
    }
    CFRelease(list);
    if (!okay) { CFRelease(result); return NULL; }
    return result;
}
