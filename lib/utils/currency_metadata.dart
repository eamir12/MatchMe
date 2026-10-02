class CurrencyNameMetadata {
  final String englishName;
  final String nativeName;

  const CurrencyNameMetadata({
    required this.englishName,
    required this.nativeName,
  });
}

const Map<String, CurrencyNameMetadata>
currencyNameMetadata = <String, CurrencyNameMetadata>{
  'AED': CurrencyNameMetadata(
    englishName: 'United Arab Emirates Dirham',
    nativeName: 'درهم إماراتي',
  ),
  'AFN': CurrencyNameMetadata(
    englishName: 'Afghan Afghani',
    nativeName: 'افغانی',
  ),
  'ALL': CurrencyNameMetadata(englishName: 'Albanian Lek', nativeName: 'Lek'),
  'AMD': CurrencyNameMetadata(englishName: 'Armenian Dram', nativeName: 'դրամ'),
  'ANG': CurrencyNameMetadata(
    englishName: 'Netherlands Antillean Guilder',
    nativeName: 'Antilliaanse gulden',
  ),
  'AOA': CurrencyNameMetadata(
    englishName: 'Angolan Kwanza',
    nativeName: 'Kwanza',
  ),
  'ARS': CurrencyNameMetadata(
    englishName: 'Argentine Peso',
    nativeName: 'Peso argentino',
  ),
  'AUD': CurrencyNameMetadata(
    englishName: 'Australian Dollar',
    nativeName: 'Australian Dollar',
  ),
  'AWG': CurrencyNameMetadata(
    englishName: 'Aruban Florin',
    nativeName: 'Arubaanse florin',
  ),
  'AZN': CurrencyNameMetadata(
    englishName: 'Azerbaijani Manat',
    nativeName: 'Azərbaycan manatı',
  ),
  'BAM': CurrencyNameMetadata(
    englishName: 'Bosnia and Herzegovina Convertible Mark',
    nativeName: 'Konvertibilna marka',
  ),
  'BBD': CurrencyNameMetadata(
    englishName: 'Barbadian Dollar',
    nativeName: 'Barbadian Dollar',
  ),
  'BDT': CurrencyNameMetadata(
    englishName: 'Bangladeshi Taka',
    nativeName: 'টাকা',
  ),
  'BGN': CurrencyNameMetadata(englishName: 'Bulgarian Lev', nativeName: 'лев'),
  'BHD': CurrencyNameMetadata(
    englishName: 'Bahraini Dinar',
    nativeName: 'دينار بحريني',
  ),
  'BIF': CurrencyNameMetadata(
    englishName: 'Burundian Franc',
    nativeName: 'faranga y’Uburundi',
  ),
  'BMD': CurrencyNameMetadata(
    englishName: 'Bermudian Dollar',
    nativeName: 'Bermudian Dollar',
  ),
  'BND': CurrencyNameMetadata(
    englishName: 'Brunei Dollar',
    nativeName: 'Dolar Brunei',
  ),
  'BOB': CurrencyNameMetadata(
    englishName: 'Bolivian Boliviano',
    nativeName: 'Boliviano',
  ),
  'BRL': CurrencyNameMetadata(
    englishName: 'Brazilian Real',
    nativeName: 'Real brasileiro',
  ),
  'BSD': CurrencyNameMetadata(
    englishName: 'Bahamian Dollar',
    nativeName: 'Bahamian Dollar',
  ),
  'BTN': CurrencyNameMetadata(
    englishName: 'Bhutanese Ngultrum',
    nativeName: 'དངུལ་ཀྲམ',
  ),
  'BWP': CurrencyNameMetadata(
    englishName: 'Botswanan Pula',
    nativeName: 'Pula',
  ),
  'BYN': CurrencyNameMetadata(
    englishName: 'Belarusian Ruble',
    nativeName: 'Беларускі рубель',
  ),
  'BZD': CurrencyNameMetadata(
    englishName: 'Belize Dollar',
    nativeName: 'Belize Dollar',
  ),
  'CAD': CurrencyNameMetadata(
    englishName: 'Canadian Dollar',
    nativeName: 'Canadian Dollar',
  ),
  'CDF': CurrencyNameMetadata(
    englishName: 'Congolese Franc',
    nativeName: 'Franc congolais',
  ),
  'CHF': CurrencyNameMetadata(
    englishName: 'Swiss Franc',
    nativeName: 'Schweizer Franken',
  ),
  'CLP': CurrencyNameMetadata(
    englishName: 'Chilean Peso',
    nativeName: 'Peso chileno',
  ),
  'CNY': CurrencyNameMetadata(englishName: 'Chinese Yuan', nativeName: '人民币'),
  'COP': CurrencyNameMetadata(
    englishName: 'Colombian Peso',
    nativeName: 'Peso colombiano',
  ),
  'CRC': CurrencyNameMetadata(
    englishName: 'Costa Rican Colon',
    nativeName: 'Colón costarricense',
  ),
  'CUP': CurrencyNameMetadata(
    englishName: 'Cuban Peso',
    nativeName: 'Peso cubano',
  ),
  'CVE': CurrencyNameMetadata(
    englishName: 'Cape Verdean Escudo',
    nativeName: 'Escudo cabo-verdiano',
  ),
  'CZK': CurrencyNameMetadata(
    englishName: 'Czech Koruna',
    nativeName: 'koruna česká',
  ),
  'DJF': CurrencyNameMetadata(
    englishName: 'Djiboutian Franc',
    nativeName: 'Franc djiboutien',
  ),
  'DKK': CurrencyNameMetadata(
    englishName: 'Danish Krone',
    nativeName: 'dansk krone',
  ),
  'DOP': CurrencyNameMetadata(
    englishName: 'Dominican Peso',
    nativeName: 'Peso dominicano',
  ),
  'DZD': CurrencyNameMetadata(
    englishName: 'Algerian Dinar',
    nativeName: 'دينار جزائري',
  ),
  'EGP': CurrencyNameMetadata(
    englishName: 'Egyptian Pound',
    nativeName: 'جنيه مصري',
  ),
  'ERN': CurrencyNameMetadata(
    englishName: 'Eritrean Nakfa',
    nativeName: 'Nakfa',
  ),
  'ETB': CurrencyNameMetadata(englishName: 'Ethiopian Birr', nativeName: 'ብር'),
  'EUR': CurrencyNameMetadata(englishName: 'Euro', nativeName: 'Euro'),
  'FJD': CurrencyNameMetadata(
    englishName: 'Fijian Dollar',
    nativeName: 'Fijian Dollar',
  ),
  'FKP': CurrencyNameMetadata(
    englishName: 'Falkland Islands Pound',
    nativeName: 'Falkland Islands Pound',
  ),
  'GBP': CurrencyNameMetadata(
    englishName: 'British Pound Sterling',
    nativeName: 'Pound Sterling',
  ),
  'GEL': CurrencyNameMetadata(englishName: 'Georgian Lari', nativeName: 'ლარი'),
  'GGP': CurrencyNameMetadata(
    englishName: 'Guernsey Pound',
    nativeName: 'Guernsey Pound',
  ),
  'GHS': CurrencyNameMetadata(englishName: 'Ghanaian Cedi', nativeName: 'Cedi'),
  'GIP': CurrencyNameMetadata(
    englishName: 'Gibraltar Pound',
    nativeName: 'Gibraltar Pound',
  ),
  'GMD': CurrencyNameMetadata(
    englishName: 'Gambian Dalasi',
    nativeName: 'Dalasi',
  ),
  'GNF': CurrencyNameMetadata(
    englishName: 'Guinean Franc',
    nativeName: 'Franc guinéen',
  ),
  'GTQ': CurrencyNameMetadata(
    englishName: 'Guatemalan Quetzal',
    nativeName: 'Quetzal',
  ),
  'GYD': CurrencyNameMetadata(
    englishName: 'Guyanaese Dollar',
    nativeName: 'Guyana Dollar',
  ),
  'HKD': CurrencyNameMetadata(
    englishName: 'Hong Kong Dollar',
    nativeName: '港元',
  ),
  'HNL': CurrencyNameMetadata(
    englishName: 'Honduran Lempira',
    nativeName: 'Lempira',
  ),
  'HRK': CurrencyNameMetadata(englishName: 'Croatian Kuna', nativeName: 'kuna'),
  'HTG': CurrencyNameMetadata(
    englishName: 'Haitian Gourde',
    nativeName: 'Gourde',
  ),
  'HUF': CurrencyNameMetadata(
    englishName: 'Hungarian Forint',
    nativeName: 'forint',
  ),
  'IDR': CurrencyNameMetadata(
    englishName: 'Indonesian Rupiah',
    nativeName: 'Rupiah',
  ),
  'ILS': CurrencyNameMetadata(
    englishName: 'Israeli New Shekel',
    nativeName: 'שקל חדש',
  ),
  'IMP': CurrencyNameMetadata(
    englishName: 'Manx Pound',
    nativeName: 'Manx Pound',
  ),
  'INR': CurrencyNameMetadata(
    englishName: 'Indian Rupee',
    nativeName: 'भारतीय रुपया',
  ),
  'IQD': CurrencyNameMetadata(
    englishName: 'Iraqi Dinar',
    nativeName: 'دينار عراقي',
  ),
  'IRR': CurrencyNameMetadata(
    englishName: 'Iranian Rial',
    nativeName: 'ریال ایران',
  ),
  'ISK': CurrencyNameMetadata(
    englishName: 'Icelandic Krona',
    nativeName: 'íslensk króna',
  ),
  'JEP': CurrencyNameMetadata(
    englishName: 'Jersey Pound',
    nativeName: 'Jersey Pound',
  ),
  'JMD': CurrencyNameMetadata(
    englishName: 'Jamaican Dollar',
    nativeName: 'Jamaican Dollar',
  ),
  'JOD': CurrencyNameMetadata(
    englishName: 'Jordanian Dinar',
    nativeName: 'دينار أردني',
  ),
  'JPY': CurrencyNameMetadata(englishName: 'Japanese Yen', nativeName: '日本円'),
  'KES': CurrencyNameMetadata(
    englishName: 'Kenyan Shilling',
    nativeName: 'Shilingi ya Kenya',
  ),
  'KGS': CurrencyNameMetadata(englishName: 'Kyrgystani Som', nativeName: 'сом'),
  'KHR': CurrencyNameMetadata(englishName: 'Cambodian Riel', nativeName: 'រៀល'),
  'KMF': CurrencyNameMetadata(
    englishName: 'Comorian Franc',
    nativeName: 'Franc comorien',
  ),
  'KPW': CurrencyNameMetadata(
    englishName: 'North Korean Won',
    nativeName: '조선 원',
  ),
  'KRW': CurrencyNameMetadata(
    englishName: 'South Korean Won',
    nativeName: '대한민국 원',
  ),
  'KWD': CurrencyNameMetadata(
    englishName: 'Kuwaiti Dinar',
    nativeName: 'دينار كويتي',
  ),
  'KYD': CurrencyNameMetadata(
    englishName: 'Cayman Islands Dollar',
    nativeName: 'Cayman Islands Dollar',
  ),
  'KZT': CurrencyNameMetadata(
    englishName: 'Kazakhstani Tenge',
    nativeName: 'теңге',
  ),
  'LAK': CurrencyNameMetadata(englishName: 'Lao Kip', nativeName: 'ກີບ'),
  'LBP': CurrencyNameMetadata(
    englishName: 'Lebanese Pound',
    nativeName: 'ليرة لبنانية',
  ),
  'LKR': CurrencyNameMetadata(
    englishName: 'Sri Lankan Rupee',
    nativeName: 'ශ්‍රී ලංකා රුපියල',
  ),
  'LRD': CurrencyNameMetadata(
    englishName: 'Liberian Dollar',
    nativeName: 'Liberian Dollar',
  ),
  'LSL': CurrencyNameMetadata(englishName: 'Lesotho Loti', nativeName: 'Loti'),
  'LYD': CurrencyNameMetadata(
    englishName: 'Libyan Dinar',
    nativeName: 'دينار ليبي',
  ),
  'MAD': CurrencyNameMetadata(
    englishName: 'Moroccan Dirham',
    nativeName: 'درهم مغربي',
  ),
  'MDL': CurrencyNameMetadata(
    englishName: 'Moldovan Leu',
    nativeName: 'leu moldovenesc',
  ),
  'MGA': CurrencyNameMetadata(
    englishName: 'Malagasy Ariary',
    nativeName: 'Ariary',
  ),
  'MKD': CurrencyNameMetadata(
    englishName: 'Macedonian Denar',
    nativeName: 'денар',
  ),
  'MMK': CurrencyNameMetadata(englishName: 'Myanmar Kyat', nativeName: 'ကျပ်'),
  'MNT': CurrencyNameMetadata(
    englishName: 'Mongolian Tugrik',
    nativeName: 'төгрөг',
  ),
  'MOP': CurrencyNameMetadata(
    englishName: 'Macanese Pataca',
    nativeName: '澳門元',
  ),
  'MRU': CurrencyNameMetadata(
    englishName: 'Mauritanian Ouguiya',
    nativeName: 'أوقية موريتانية',
  ),
  'MUR': CurrencyNameMetadata(
    englishName: 'Mauritian Rupee',
    nativeName: 'Roupie mauricienne',
  ),
  'MVR': CurrencyNameMetadata(
    englishName: 'Maldivian Rufiyaa',
    nativeName: 'ރުފިޔާ',
  ),
  'MWK': CurrencyNameMetadata(
    englishName: 'Malawian Kwacha',
    nativeName: 'Kwacha',
  ),
  'MXN': CurrencyNameMetadata(
    englishName: 'Mexican Peso',
    nativeName: 'Peso mexicano',
  ),
  'MYR': CurrencyNameMetadata(
    englishName: 'Malaysian Ringgit',
    nativeName: 'Ringgit Malaysia',
  ),
  'MZN': CurrencyNameMetadata(
    englishName: 'Mozambican Metical',
    nativeName: 'Metical',
  ),
  'NAD': CurrencyNameMetadata(
    englishName: 'Namibian Dollar',
    nativeName: 'Namibian Dollar',
  ),
  'NGN': CurrencyNameMetadata(
    englishName: 'Nigerian Naira',
    nativeName: 'Naira',
  ),
  'NIO': CurrencyNameMetadata(
    englishName: 'Nicaraguan Cordoba',
    nativeName: 'Córdoba',
  ),
  'NOK': CurrencyNameMetadata(
    englishName: 'Norwegian Krone',
    nativeName: 'norsk krone',
  ),
  'NPR': CurrencyNameMetadata(
    englishName: 'Nepalese Rupee',
    nativeName: 'नेपाली रुपियाँ',
  ),
  'NZD': CurrencyNameMetadata(
    englishName: 'New Zealand Dollar',
    nativeName: 'New Zealand Dollar',
  ),
  'OMR': CurrencyNameMetadata(
    englishName: 'Omani Rial',
    nativeName: 'ريال عماني',
  ),
  'PAB': CurrencyNameMetadata(
    englishName: 'Panamanian Balboa',
    nativeName: 'Balboa',
  ),
  'PEN': CurrencyNameMetadata(englishName: 'Peruvian Sol', nativeName: 'Sol'),
  'PGK': CurrencyNameMetadata(
    englishName: 'Papua New Guinean Kina',
    nativeName: 'Kina',
  ),
  'PHP': CurrencyNameMetadata(
    englishName: 'Philippine Peso',
    nativeName: 'Piso ng Pilipinas',
  ),
  'PKR': CurrencyNameMetadata(
    englishName: 'Pakistani Rupee',
    nativeName: 'پاکستانی روپیہ',
  ),
  'PLN': CurrencyNameMetadata(englishName: 'Polish Zloty', nativeName: 'złoty'),
  'PYG': CurrencyNameMetadata(
    englishName: 'Paraguayan Guarani',
    nativeName: 'Guaraní',
  ),
  'QAR': CurrencyNameMetadata(
    englishName: 'Qatari Riyal',
    nativeName: 'ريال قطري',
  ),
  'RON': CurrencyNameMetadata(
    englishName: 'Romanian Leu',
    nativeName: 'leu românesc',
  ),
  'RSD': CurrencyNameMetadata(
    englishName: 'Serbian Dinar',
    nativeName: 'српски динар',
  ),
  'RUB': CurrencyNameMetadata(
    englishName: 'Russian Ruble',
    nativeName: 'российский рубль',
  ),
  'RWF': CurrencyNameMetadata(
    englishName: 'Rwandan Franc',
    nativeName: 'faranga y’u Rwanda',
  ),
  'SAR': CurrencyNameMetadata(
    englishName: 'Saudi Riyal',
    nativeName: 'ريال سعودي',
  ),
  'SBD': CurrencyNameMetadata(
    englishName: 'Solomon Islands Dollar',
    nativeName: 'Solomon Islands Dollar',
  ),
  'SCR': CurrencyNameMetadata(
    englishName: 'Seychellois Rupee',
    nativeName: 'Roupi seselwa',
  ),
  'SDG': CurrencyNameMetadata(
    englishName: 'Sudanese Pound',
    nativeName: 'جنيه سوداني',
  ),
  'SEK': CurrencyNameMetadata(
    englishName: 'Swedish Krona',
    nativeName: 'svensk krona',
  ),
  'SGD': CurrencyNameMetadata(
    englishName: 'Singapore Dollar',
    nativeName: 'Singapore Dollar',
  ),
  'SHP': CurrencyNameMetadata(
    englishName: 'Saint Helena Pound',
    nativeName: 'Saint Helena Pound',
  ),
  'SLE': CurrencyNameMetadata(
    englishName: 'Sierra Leonean Leone',
    nativeName: 'Leone',
  ),
  'SOS': CurrencyNameMetadata(
    englishName: 'Somali Shilling',
    nativeName: 'Shilin Soomaali',
  ),
  'SRD': CurrencyNameMetadata(
    englishName: 'Surinamese Dollar',
    nativeName: 'Surinaamse dollar',
  ),
  'SSP': CurrencyNameMetadata(
    englishName: 'South Sudanese Pound',
    nativeName: 'South Sudanese Pound',
  ),
  'STN': CurrencyNameMetadata(
    englishName: 'Sao Tome and Principe Dobra',
    nativeName: 'Dobra',
  ),
  'SVC': CurrencyNameMetadata(
    englishName: 'Salvadoran Colon',
    nativeName: 'Colón salvadoreño',
  ),
  'SYP': CurrencyNameMetadata(
    englishName: 'Syrian Pound',
    nativeName: 'ليرة سورية',
  ),
  'SZL': CurrencyNameMetadata(
    englishName: 'Swazi Lilangeni',
    nativeName: 'Lilangeni',
  ),
  'THB': CurrencyNameMetadata(englishName: 'Thai Baht', nativeName: 'บาท'),
  'TJS': CurrencyNameMetadata(
    englishName: 'Tajikistani Somoni',
    nativeName: 'сомонӣ',
  ),
  'TMT': CurrencyNameMetadata(
    englishName: 'Turkmenistani Manat',
    nativeName: 'manat',
  ),
  'TND': CurrencyNameMetadata(
    englishName: 'Tunisian Dinar',
    nativeName: 'دينار تونسي',
  ),
  'TOP': CurrencyNameMetadata(
    englishName: 'Tongan Paanga',
    nativeName: 'Paʻanga',
  ),
  'TRY': CurrencyNameMetadata(
    englishName: 'Turkish Lira',
    nativeName: 'Türk lirası',
  ),
  'TTD': CurrencyNameMetadata(
    englishName: 'Trinidad and Tobago Dollar',
    nativeName: 'Trinidad and Tobago Dollar',
  ),
  'TWD': CurrencyNameMetadata(
    englishName: 'New Taiwan Dollar',
    nativeName: '新台幣',
  ),
  'TZS': CurrencyNameMetadata(
    englishName: 'Tanzanian Shilling',
    nativeName: 'Shilingi ya Tanzania',
  ),
  'UAH': CurrencyNameMetadata(
    englishName: 'Ukrainian Hryvnia',
    nativeName: 'гривня',
  ),
  'UGX': CurrencyNameMetadata(
    englishName: 'Ugandan Shilling',
    nativeName: 'Uganda Shilling',
  ),
  'USD': CurrencyNameMetadata(
    englishName: 'United States Dollar',
    nativeName: 'United States Dollar',
  ),
  'UYU': CurrencyNameMetadata(
    englishName: 'Uruguayan Peso',
    nativeName: 'Peso uruguayo',
  ),
  'UZS': CurrencyNameMetadata(
    englishName: 'Uzbekistani Som',
    nativeName: 'soʻm',
  ),
  'VES': CurrencyNameMetadata(
    englishName: 'Venezuelan Bolivar',
    nativeName: 'Bolívar',
  ),
  'VND': CurrencyNameMetadata(
    englishName: 'Vietnamese Dong',
    nativeName: 'đồng',
  ),
  'VUV': CurrencyNameMetadata(englishName: 'Vanuatu Vatu', nativeName: 'Vatu'),
  'WST': CurrencyNameMetadata(englishName: 'Samoan Tala', nativeName: 'Tālā'),
  'XAF': CurrencyNameMetadata(
    englishName: 'Central African CFA Franc',
    nativeName: 'Franc CFA',
  ),
  'XCD': CurrencyNameMetadata(
    englishName: 'East Caribbean Dollar',
    nativeName: 'East Caribbean Dollar',
  ),
  'XOF': CurrencyNameMetadata(
    englishName: 'West African CFA Franc',
    nativeName: 'Franc CFA',
  ),
  'XPF': CurrencyNameMetadata(
    englishName: 'CFP Franc',
    nativeName: 'franc CFP',
  ),
  'YER': CurrencyNameMetadata(
    englishName: 'Yemeni Rial',
    nativeName: 'ريال يمني',
  ),
  'ZAR': CurrencyNameMetadata(
    englishName: 'South African Rand',
    nativeName: 'South African Rand',
  ),
  'ZMW': CurrencyNameMetadata(
    englishName: 'Zambian Kwacha',
    nativeName: 'Kwacha',
  ),
  'ZWL': CurrencyNameMetadata(
    englishName: 'Zimbabwean Dollar',
    nativeName: 'Zimbabwean Dollar',
  ),
};
