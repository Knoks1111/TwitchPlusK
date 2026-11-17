/*
 * tpK-picker-cell.m
 * Extrait de tpK-core-manager.m lors du nettoyage du picker.
 */

#import "Picker/tpK-picker-cell.h"
#import "Emote/tpK-emote-animation-engine.h"
#import "Emote/tpK-emote-image-cache.h"
#import "UI/tpK-oled-mode.h"

@implementation TPKEmotePickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _emoteImageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _emoteImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _emoteImageView.contentMode = UIViewContentModeScaleAspectFit;
        _emoteImageView.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_emoteImageView];

        // Pastille pleine en haut à droite pour distinguer les favoris.
        _favoriteStarView = [[UIImageView alloc] init];
        _favoriteStarView.backgroundColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
        _favoriteStarView.layer.cornerRadius = 6;
        _favoriteStarView.clipsToBounds = YES;
        _favoriteStarView.contentMode = UIViewContentModeCenter;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:6 weight:UIImageSymbolWeightBold];
        _favoriteStarView.image = [[UIImage systemImageNamed:@"star.fill" withConfiguration:cfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _favoriteStarView.tintColor = [UIColor whiteColor];
        _favoriteStarView.hidden = YES;
        // Ajouté à la cellule pour dépasser de contentView, qui masque ses bords.
        [self addSubview:_favoriteStarView];

        _providerBadgeLabel = [[UILabel alloc] init];
        _providerBadgeLabel.font = [UIFont systemFontOfSize:7.0 weight:UIFontWeightBold];
        _providerBadgeLabel.textAlignment = NSTextAlignmentCenter;
        _providerBadgeLabel.textColor = UIColor.whiteColor;
        _providerBadgeLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
        _providerBadgeLabel.layer.cornerRadius = 3.0;
        _providerBadgeLabel.clipsToBounds = YES;
        _providerBadgeLabel.hidden = YES;
        [self addSubview:_providerBadgeLabel];

        self.clipsToBounds = NO; // le badge favori déborde légèrement du coin
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 8;
        CGFloat onePixel = 1.0 / [UIScreen mainScreen].scale;
        self.contentView.layer.borderWidth = onePixel;
        self.backgroundColor = [UIColor clearColor];
        [self tpk_applyOLEDColors];
    }
    return self;
}

- (void)tpk_applyOLEDColors {
    BOOL oled = TPKOLEDModeEnabled();
    // En mode OLED, la carte et sa bordure sont plus sombres.
    UIColor *cardColor = oled
        ? [UIColor colorWithWhite:0.05 alpha:1.0]
        : [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
    UIColor *borderColor = oled
        ? [UIColor colorWithWhite:0.12 alpha:1.0]
        : [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
    self.contentView.backgroundColor = cardColor;
    self.contentView.layer.borderColor = borderColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize cs = self.bounds.size;
    self.favoriteStarView.frame = CGRectMake(cs.width - 9, -3, 12, 12);
    self.providerBadgeLabel.frame = CGRectMake(2, cs.height - 12, 24, 10);
}

- (void)resetContent {
    [self.animationFrameRequest cancel];
    self.animationFrameRequest = nil;
    self.imageLoadGeneration += 1;
    self.animationGeneration += 1;
    self.wantsAnimation = NO;
    self.emoteImageView.image = nil;
    self.favoriteStarView.hidden = YES;
    self.providerBadgeLabel.hidden = YES;
    self.providerBadgeLabel.text = nil;
    self.currentEmoteKey = nil;
    // Retire la cellule de l'engine avant de la réutiliser pour une autre emote.
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:self];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self resetContent];
}

@end
