#import <Cocoa/Cocoa.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <libproc.h>
#import <dlfcn.h>

int server_fd = -1;
NSString *pendingScript = @"none";
BOOL isInjected = NO;

int inject_dylib(pid_t pid, const char *dylib_path) {
    kern_return_t kr;
    task_t task;
    
    kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        printf("task_for_pid failed: %s\n", mach_error_string(kr));
        return -1;
    }
    
    mach_vm_address_t addr = 0;
    kr = mach_vm_allocate(task, &addr, strlen(dylib_path) + 1, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return -1;
    
    kr = mach_vm_write(task, addr, (vm_offset_t)dylib_path, (mach_msg_type_number_t)strlen(dylib_path) + 1);
    
#if defined(__arm64__)
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    void *dlopen_addr = dlsym(RTLD_DEFAULT, "dlopen");
    state.__pc = (uint64_t)dlopen_addr;
    state.__x[0] = (uint64_t)addr;
    state.__x[1] = (uint64_t)RTLD_NOW;
    thread_act_t thread;
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
#else
    x86_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    void *dlopen_addr = dlsym(RTLD_DEFAULT, "dlopen");
    state.__rip = (uint64_t)dlopen_addr;
    state.__rdi = (uint64_t)addr;
    state.__rsi = (uint64_t)RTLD_NOW;
    thread_act_t thread;
    kr = thread_create_running(task, x86_THREAD_STATE64, (thread_state_t)&state, x86_THREAD_STATE64_COUNT, &thread);
#endif
    
    if (kr != KERN_SUCCESS) return -1;
    return 0;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) NSWindow *toastWindow;
@property (strong) NSTextField *userField;
@property (strong) NSSecureTextField *passField;
@property (strong) NSView *loginView;
@property (strong) NSView *execView;
@property (strong) NSTabView *tabView;
@property (assign) BOOL isAdmin;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window center];
    [self.window setTitle:@"Bozo Executer"];
    [self.window setBackgroundColor:[NSColor blackColor]];
    [self.window makeKeyAndOrderFront:nil];
    
    [self setupLoginUI];
    [self setupExecutorUI];
    
    self.execView.hidden = YES;
    [self.window setContentView:self.loginView];
    
    [self startBridge];
}

- (void)startBridge {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in address;
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(8081);
        if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) return;
        if (listen(server_fd, 3) < 0) return;
        
        while (1) {
            int new_socket = accept(server_fd, NULL, NULL);
            if (new_socket < 0) continue;
            char buffer[1024] = {0};
            read(new_socket, buffer, 1024);
            NSString *req = [NSString stringWithUTF8String:buffer];
            if ([req containsString:@"GET /fetch"]) {
                NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\n\r\n%@", pendingScript];
                write(new_socket, [response UTF8String], strlen([response UTF8String]));
                pendingScript = @"none";
            } else {
                NSString *response = @"HTTP/1.1 404 Not Found\r\n\r\n";
                write(new_socket, [response UTF8String], strlen([response UTF8String]));
            }
            close(new_socket);
        }
    });
}

- (void)setupLoginUI {
    [self.window setContentSize:NSMakeSize(400, 350)];
    self.loginView = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    
    NSTextField *title = [NSTextField labelWithString:@"Bozo Executer Key"];
    title.font = [NSFont boldSystemFontOfSize:24];
    title.textColor = [NSColor whiteColor];
    title.alignment = NSTextAlignmentLeft;
    title.frame = NSMakeRect(20, 250, 360, 40);
    [self.loginView addSubview:title];
    
    self.userField = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 180, 300, 30)];
    self.userField.placeholderString = @"Username";
    self.userField.alignment = NSTextAlignmentCenter;
    [self.loginView addSubview:self.userField];
    
    self.passField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(50, 140, 300, 30)];
    self.passField.placeholderString = @"Password";
    self.passField.alignment = NSTextAlignmentCenter;
    [self.loginView addSubview:self.passField];
    
    NSButton *btn = [NSButton buttonWithTitle:@"Confirm" target:self action:@selector(checkLogin)];
    btn.frame = NSMakeRect(150, 80, 100, 35);
    btn.bezelStyle = NSBezelStyleRounded;
    [self.loginView addSubview:btn];
}

- (void)checkLogin {
    NSString *u = self.userField.stringValue;
    NSString *p = self.passField.stringValue;
    if ([u isEqualToString:@"teambozoisthebest"] && [p isEqualToString:@"Thisisownerinfo"]) {
        self.isAdmin = YES; [self showWarning];
    } else if ([u isEqualToString:@"NormalUser"] && [p isEqualToString:@"IamNotAskidLol"]) {
        self.isAdmin = NO; [self showWarning];
    } else {
        NSAlert *a = [[NSAlert alloc] init]; [a setMessageText:@"Invalid credentials."]; [a runModal];
    }
}

- (void)showWarning {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"WARNING"];
    [alert setInformativeText:@"if u leak this u will get pernamently banned from this executer forever!"];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert addButtonWithTitle:@"Understood"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        self.loginView.hidden = YES; self.execView.hidden = NO;
        [self.window setContentSize:NSMakeSize(800, 600)];
        [self.window setContentView:self.execView];
        if (!self.isAdmin) {
            for (NSView *v in self.execView.subviews) {
                if ([v isKindOfClass:[NSButton class]] && [((NSButton *)v).title isEqualToString:@"+ Add Tab"]) v.hidden = YES;
            }
        }
    }];
}

- (void)setupExecutorUI {
    self.execView = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    NSString *bgPath = [[NSBundle mainBundle] pathForResource:@"bg" ofType:@"png"];
    if (bgPath) {
        NSImageView *bgView = [[NSImageView alloc] initWithFrame:self.execView.bounds];
        [bgView setImage:[[NSImage alloc] initWithContentsOfFile:bgPath]];
        [bgView setImageScaling:NSImageScaleAxesIndependently];
        [self.execView addSubview:bgView];
    }
    
    NSTextField *topLabel = [NSTextField labelWithString:@"BOZO EXECUTER - PRIVATE"];
    topLabel.font = [NSFont boldSystemFontOfSize:20];
    topLabel.textColor = [NSColor whiteColor];
    topLabel.frame = NSMakeRect(20, 550, 400, 30);
    [self.execView addSubview:topLabel];
    
    NSButton *addTabBtn = [NSButton buttonWithTitle:@"+ Add Tab" target:self action:@selector(addTab)];
    addTabBtn.frame = NSMakeRect(650, 550, 120, 30);
    [self.execView addSubview:addTabBtn];
    
    self.tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(20, 90, 760, 440)];
    [self.execView addSubview:self.tabView];
    [self loadTabs];
    
    NSButton *execBtn = [NSButton buttonWithTitle:@"EXECUTE" target:self action:@selector(executeScript)];
    execBtn.frame = NSMakeRect(20, 20, 120, 40);
    [self.execView addSubview:execBtn];
    
    NSButton *clearBtn = [NSButton buttonWithTitle:@"CLEAR" target:self action:@selector(clearScript)];
    clearBtn.frame = NSMakeRect(160, 20, 120, 40);
    [self.execView addSubview:clearBtn];
    
    NSButton *injectBtn = [NSButton buttonWithTitle:@"INJECT" target:self action:@selector(inject)];
    injectBtn.frame = NSMakeRect(300, 20, 120, 40);
    [self.execView addSubview:injectBtn];
}

- (void)loadTabs {
    NSString *savePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BozoExecuterTabs.plist"];
    NSArray *savedTabs = [NSArray arrayWithContentsOfFile:savePath];
    if (savedTabs.count == 0) {
        [self createMainTab];
    } else {
        for (NSDictionary *dict in savedTabs) {
            NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:dict[@"name"]];
            [item setLabel:dict[@"name"]];
            NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 750, 430)];
            
            if ([dict[@"name"] isEqualToString:@"Main"]) {
                NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 750, 430)];
                [scroll setHasVerticalScroller:YES];
                [scroll setBackgroundColor:[NSColor colorWithWhite:0 alpha:0.6]];
                NSTextView *editor = [[NSTextView alloc] initWithFrame:scroll.bounds];
                [editor setBackgroundColor:[NSColor clearColor]];
                [editor setTextColor:[NSColor whiteColor]];
                [editor setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
                [editor setString:@"-- Lua Script Here"];
                [editor setEditable:YES];
                [scroll setDocumentView:editor];
                [view addSubview:scroll];
            } else {
                NSButton *addBtnBtn = [NSButton buttonWithTitle:@"+ Add Script Button" target:self action:@selector(addScriptButton:)];
                addBtnBtn.frame = NSMakeRect(10, 390, 160, 30);
                [view addSubview:addBtnBtn];
                
                int y = 340;
                for (NSDictionary *btn in dict[@"buttons"]) {
                    NSButton *scriptBtn = [NSButton buttonWithTitle:btn[@"name"] target:self action:@selector(runScriptButton:)];
                    scriptBtn.frame = NSMakeRect(10, y, 160, 30);
                    [scriptBtn setToolTip:btn[@"script"]];
                    [view addSubview:scriptBtn];
                    y -= 40;
                }
            }
            [item setView:view];
            [self.tabView addTabViewItem:item];
        }
    }
}

- (void)createMainTab {
    NSTabViewItem *mainTab = [[NSTabViewItem alloc] initWithIdentifier:@"Main"];
    [mainTab setLabel:@"Main"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 750, 430)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBackgroundColor:[NSColor colorWithWhite:0 alpha:0.6]];
    NSTextView *editor = [[NSTextView alloc] initWithFrame:scroll.bounds];
    [editor setBackgroundColor:[NSColor clearColor]];
    [editor setTextColor:[NSColor whiteColor]];
    [editor setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    [editor setString:@"-- Lua Script Here"];
    [editor setEditable:YES];
    [scroll setDocumentView:editor];
    [mainTab setView:scroll];
    [self.tabView addTabViewItem:mainTab];
}

- (void)saveTabs {
    NSMutableArray *tabs = [NSMutableArray array];
    for (NSTabViewItem *item in self.tabView.tabViewItems) {
        NSMutableArray *btns = [NSMutableArray array];
        for (NSView *v in item.view.subviews) {
            if ([v isKindOfClass:[NSButton class]] && ![((NSButton *)v).title isEqualToString:@"+ Add Script Button"]) {
                [btns addObject:@{@"name": ((NSButton *)v).title, @"script": [((NSButton *)v) toolTip] ?: @""}];
            }
        }
        [tabs addObject:@{@"name": item.label, @"buttons": btns}];
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BozoExecuterTabs.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [tabs writeToFile:path atomically:YES];
}

- (void)addTab {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"New Tab Name:"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [alert setAccessoryView:input];
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        if (input.stringValue.length > 0) {
            NSTabViewItem *newItem = [[NSTabViewItem alloc] initWithIdentifier:input.stringValue];
            [newItem setLabel:input.stringValue];
            NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 750, 430)];
            NSButton *addBtnBtn = [NSButton buttonWithTitle:@"+ Add Script Button" target:self action:@selector(addScriptButton:)];
            addBtnBtn.frame = NSMakeRect(10, 390, 160, 30);
            [view addSubview:addBtnBtn];
            [newItem setView:view];
            [self.tabView addTabViewItem:newItem];
            [self saveTabs];
        }
    }
}

- (void)addScriptButton:(NSButton *)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Create Script Button"];
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 70, 280, 24)];
    nameField.placeholderString = @"Button Name";
    [accessory addSubview:nameField];
    NSTextField *scriptField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 30, 280, 24)];
    scriptField.placeholderString = @"Lua Script";
    [accessory addSubview:scriptField];
    [alert setAccessoryView:accessory];
    [alert addButtonWithTitle:@"Confirm"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        if (nameField.stringValue.length > 0) {
            NSButton *scriptBtn = [NSButton buttonWithTitle:nameField.stringValue target:self action:@selector(runScriptButton:)];
            scriptBtn.frame = NSMakeRect(10, 340 - (sender.superview.subviews.count * 40), 160, 30);
            [scriptBtn setToolTip:scriptField.stringValue];
            [sender.superview addSubview:scriptBtn];
            [self saveTabs];
        }
    }
}

- (void)runScriptButton:(NSButton *)sender {
    pendingScript = sender.toolTip;
    NSAlert *a = [[NSAlert alloc] init]; [a setMessageText:[NSString stringWithFormat:@"Sent to Roblox: %@", sender.title]]; [a runModal];
}

- (void)clearScript {
    NSTabViewItem *item = self.tabView.selectedTabViewItem;
    if ([item.view isKindOfClass:[NSScrollView class]]) [((NSTextView *)((NSScrollView *)item.view).documentView) setString:@""];
}

- (void)executeScript {
    if (!isInjected) return;
    NSTabViewItem *item = self.tabView.selectedTabViewItem;
    if ([item.view isKindOfClass:[NSScrollView class]]) {
        NSString *script = ((NSTextView *)((NSScrollView *)item.view).documentView).string;
        pendingScript = script;
    }
}

- (void)showToast {
    self.toastWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 50)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [self.toastWindow setBackgroundColor:[NSColor clearColor]];
    [self.toastWindow setOpaque:NO];
    [self.toastWindow setLevel:NSFloatingWindowLevel];
    
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 50)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.8 blue:0.2 alpha:0.9].CGColor;
    view.layer.cornerRadius = 10;
    [self.toastWindow setContentView:view];
    
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 15, 200, 20)];
    [label setStringValue:@"Injected!"];
    [label setAlignment:NSTextAlignmentCenter];
    [label setTextColor:[NSColor whiteColor]];
    [label setFont:[NSFont boldSystemFontOfSize:16]];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [view addSubview:label];
    
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenRect = [screen visibleFrame];
    [self.toastWindow setFrameOrigin:NSMakePoint(NSMaxX(screenRect) - 220, NSMinY(screenRect) + 20)];
    [self.toastWindow makeKeyAndOrderFront:nil];
    
    [self performSelector:@selector(closeToast) withObject:nil afterDelay:3.0];
}

- (void)closeToast {
    [self.toastWindow close];
    self.toastWindow = nil;
}

- (void)inject {
    NSArray *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    pid_t robloxPid = -1;
    
    for (NSRunningApplication *app in apps) {
        if ([[app bundleIdentifier] isEqualToString:@"com.roblox.Roblox"] || [[app bundleIdentifier] isEqualToString:@"com.roblox.RobloxPlayer"]) {
            robloxPid = app.processIdentifier;
            break;
        }
    }
    
    if (robloxPid == -1) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Roblox is not open!"];
        [alert setInformativeText:@"Please open Roblox first."];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert runModal];
        return;
    }
    
    NSString *dylibPath = [[NSBundle mainBundle] pathForResource:@"libBozo" ofType:@"dylib"];
    if (inject_dylib(robloxPid, [dylibPath UTF8String]) == 0) {
        isInjected = YES;
        [self showToast];
        
        NSString *bridgeLua = @"local http = game:GetService('HttpService')\nlocal sg = Instance.new('Folder')\nsg.Name = 'ServerCoreScripts'\nsg.Parent = game:GetService('CoreGui')\ntask.spawn(function()\n    while task.wait(0.5) do\n        local success, err = pcall(function()\n            local response = http:GetAsync('http://127.0.0.1:8081/fetch')\n            if response and response ~= 'none' then\n                local func = loadstring(response)\n                if func then func() end\n            end\n        end)\n    end\nend)";
        
        NSString *autoexecPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Roblox/autoexec/bridge.lua"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:[autoexecPath stringByDeletingLastPathComponent]]) {
            [bridgeLua writeToFile:autoexecPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Injection Failed."];
        [alert setInformativeText:@"Make sure SIP is disabled and you are running the app as root (sudo)."];
        [alert setAlertStyle:NSAlertStyleCritical];
        [alert runModal];
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
