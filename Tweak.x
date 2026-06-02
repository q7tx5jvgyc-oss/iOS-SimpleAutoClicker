#import <UIKit/UIKit.h>
#include <dlfcn.h>
#import "ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/ZSFakeTouch.h"

// --- نموذج بيانات النقرات ---
@interface TapPointModel : NSObject
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, strong) UIView *indicatorView; // الدائرة الحمراء على الشاشة

- (NSDictionary *)toDictionary;
- (void)updateWithDictionary:(NSDictionary *)dict;
@end

@implementation TapPointModel
- (NSDictionary *)toDictionary {
    return @{
        @"isEnabled": @(self.isEnabled),
        @"x": @(self.x),
        @"y": @(self.y)
    };
}

- (void)updateWithDictionary:(NSDictionary *)dict {
    if (!dict) return;
    self.isEnabled = [dict[@"isEnabled"] boolValue];
    self.x = [dict[@"x"] floatValue];
    self.y = [dict[@"y"] floatValue];
}
@end

// --- واجهة النوافذ الشفافة المانعة للاحتجاز العشوائي ---
@interface FloatingOverlayWindow : UIWindow
@end

@implementation FloatingOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) {
        return nil; // تمرير اللمس للخلفية إذا تم الضغط خارج القائمة
    }
    return hitView;
}

- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
@end

// --- مدير الأوتو كليكر الأساسي والواجهات ---
@interface AutoClickerManager : NSObject
@property (nonatomic, strong) FloatingOverlayWindow *overlayWindow;
@property (nonatomic, strong) UIButton *floatingButton; // الزر العائم الأزرق
@property (nonatomic, strong) UIView *settingsPanel;    // القائمة المربعة الصغيرة
@property (nonatomic, strong) UILabel *intervalLbl;     // نص عرض السرعة
@property (nonatomic, strong) UISlider *intervalSlider; // شريط التحكم بالسرعة
@property (nonatomic, strong) NSMutableArray<TapPointModel *> *points;
@property (nonatomic, assign) CGFloat clickInterval;    // السرعة بالثواني
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) dispatch_source_t timer;  // مؤقت النقر
+ (instancetype)sharedInstance;
- (void)setupUI;
@end

@implementation AutoClickerManager

+ (instancetype)sharedInstance {
    static AutoClickerManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoClickerManager alloc] init];
    });
    return instance;
}

- (NSString *)settingsKeyForCurrentApp {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) bundleID = @"unknown_app";
    return [NSString stringWithFormat:@"AutoClicker_Settings_%@", bundleID];
}

- (void)saveSettings {
    NSMutableArray *pointsArray = [NSMutableArray array];
    for (TapPointModel *model in self.points) {
        [pointsArray addObject:[model toDictionary]];
    }
    NSDictionary *settings = @{
        @"clickInterval": @(self.clickInterval),
        @"points": pointsArray
    };
    [[NSUserDefaults standardUserDefaults] setObject:settings forKey:[self settingsKeyForCurrentApp]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)loadSettings {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self settingsKeyForCurrentApp]];
    if (settings) {
        if (settings[@"clickInterval"]) {
            self.clickInterval = [settings[@"clickInterval"] floatValue];
        }
        NSArray *pointsArray = settings[@"points"];
        if (pointsArray && pointsArray.count == 10) {
            for (int i = 0; i < 10; i++) {
                [self.points[i] updateWithDictionary:pointsArray[i]];
            }
        }
    } else {
        self.clickInterval = 0.1;
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        for (int i = 0; i < 10; i++) {
            self.points[i].isEnabled = NO;
            self.points[i].x = screenSize.width / 2;
            self.points[i].y = screenSize.height / 2;
        }
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _clickInterval = 0.1;
        _points = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            [_points addObject:[[TapPointModel alloc] init]];
        }
        [self loadSettings];
    }
    return self;
}

- (void)setupUI {
    if (self.overlayWindow) return;
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    
    // 1. إنشاء نافذة النظام الفوقية الشفافة
    self.overlayWindow = [[FloatingOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 2;
    self.overlayWindow.hidden = NO;
    self.overlayWindow.backgroundColor = [UIColor clearColor];

    // 2. إعداد الدوائر المؤشرة للنقاط على الشاشة
    for (int i = 0; i < 10; i++) {
        TapPointModel *model = self.points[i];
        UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        indicator.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.7];
        indicator.layer.cornerRadius = 13;
        indicator.layer.borderWidth = 1.5;
        indicator.layer.borderColor = [UIColor whiteColor].CGColor;
        indicator.center = CGPointMake(model.x, model.y);
        indicator.hidden = !model.isEnabled;
        indicator.userInteractionEnabled = YES; // تفعيل السحب المباشر للهدف باليد
        
        UILabel *numLbl = [[UILabel alloc] initWithFrame:indicator.bounds];
        numLbl.text = [NSString stringWithFormat:@"%d", i+1];
        numLbl.textColor = [UIColor whiteColor];
        numLbl.textAlignment = NSTextAlignmentCenter;
        numLbl.font = [UIFont boldSystemFontOfSize:13];
        [indicator addSubview:numLbl];
        
        // إضافة مستشعر حركة لسحب الأهداف مباشرة في اللعبة
        indicator.tag = i;
        UIPanGestureRecognizer *panTarget = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleTargetPan:)];
        [indicator addGestureRecognizer:panTarget];
        
        [self.overlayWindow addSubview:indicator];
        model.indicatorView = indicator;
    }
    
    // 3. تصميم الزر العائم الأزرق المستدير (Floating Button)
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(20, 150, 55, 55);
    self.floatingButton.backgroundColor = [UIColor systemBlueColor];
    self.floatingButton.layer.cornerRadius = 27.5;
    [self.floatingButton setTitle:@"🖱️" forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont systemFontOfSize:24];
    self.floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingButton.layer.shadowOpacity = 0.4;
    self.floatingButton.layer.shadowOffset = CGSizeMake(0, 3);
    
    [self.floatingButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    
    UIPanGestureRecognizer *panBtn = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleButtonPan:)];
    [self.floatingButton addGestureRecognizer:panBtn];
    [self.overlayWindow addSubview:self.floatingButton];

    // 4. تصميم القائمة المربعة الصغيرة المنبثقة (Settings Panel)
    self.settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 270, 310)];
    self.settingsPanel.center = self.overlayWindow.center;
    self.settingsPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    self.settingsPanel.layer.cornerRadius = 16;
    self.settingsPanel.layer.borderWidth = 1.5;
    self.settingsPanel.layer.borderColor = [UIColor systemBlueColor].CGColor;
    self.settingsPanel.hidden = YES;
    [self.overlayWindow addSubview:self.settingsPanel];
    
    // عنوان الواجهة المربعة
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 15, 250, 25)];
    titleLabel.text = @"لوحة الأوتو كليكر";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.settingsPanel addSubview:titleLabel];
    
    // زِر: إضافة هدف (تفعيل النقطة التالية المتاحة)
    UIButton *btnAdd = [UIButton buttonWithType:UIButtonTypeSystem];
    btnAdd.frame = CGRectMake(20, 55, 230, 42);
    btnAdd.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    [btnAdd setTitle:@"➕ إضافة هدف جديد" forState:UIControlStateNormal];
    [btnAdd setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnAdd.layer.cornerRadius = 10;
    btnAdd.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [btnAdd addTarget:self action:@selector(addNewTargetPoint) forControlEvents:UIControlEventTouchUpInside];
    [self.settingsPanel addSubview:btnAdd];
    
    // نص عرض السرعة الحالية
    self.intervalLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, 230, 20)];
    self.intervalLbl.text = [NSString stringWithFormat:@"سرعة النقر: %.2f ثانية", self.clickInterval];
    self.intervalLbl.textColor = [UIColor systemGray2Color];
    self.intervalLbl.textAlignment = NSTextAlignmentCenter;
    self.intervalLbl.font = [UIFont systemFontOfSize:13];
    [self.settingsPanel addSubview:self.intervalLbl];
    
    // شريط زيادة وتقليل السرعة (Slider)
    self.intervalSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, 135, 230, 30)];
    self.intervalSlider.minimumValue = 0.02; // أسرع شيء (20 جزء من الثانية)
    self.intervalSlider.maximumValue = 2.0;  // أبطأ شيء (ثانيتين)
    self.intervalSlider.value = self.clickInterval;
    self.intervalSlider.minimumTrackTintColor = [UIColor systemBlueColor];
    [self.intervalSlider addTarget:self action:@selector(intervalChanged:) forControlEvents:UIControlEventValueChanged];
    [self.settingsPanel addSubview:self.intervalSlider];
    
    // زِر: تشغيل (◀️)
    UIButton *btnStart = [UIButton buttonWithType:UIButtonTypeSystem];
    btnStart.frame = CGRectMake(20, 185, 230, 45);
    btnStart.backgroundColor = [UIColor systemGreenColor];
    [btnStart setTitle:@"▶️ تشغـيـل" forState:UIControlStateNormal];
