package com.example.balanceandroid.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Bed
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Cake
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.Checkroom
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Fastfood
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.LocalGroceryStore
import androidx.compose.material.icons.filled.MedicalServices
import androidx.compose.material.icons.filled.Medication
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PedalBike
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Print
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Sell
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.Work
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.balanceandroid.data.CategoryDesign
import com.example.balanceandroid.data.CategoryTotal
import com.example.balanceandroid.ui.theme.BalanceGreen
import com.example.balanceandroid.ui.theme.BalanceTheme
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.util.Currency
import java.util.Locale

fun formatMoney(value: Double, currency: String): String = runCatching {
    NumberFormat.getCurrencyInstance(Locale.getDefault()).apply {
        this.currency = Currency.getInstance(currency)
        maximumFractionDigits = if (value % 1.0 == 0.0) 0 else 2
    }.format(value)
}.getOrElse { "%.2f %s".format(value, currency) }

fun colorFor(name: String): Color = when (name) {
    "red" -> Color(0xFFE05252)
    "orange" -> Color(0xFFF28C38)
    "yellow" -> Color(0xFFE0AC24)
    "green" -> Color(0xFF16A36A)
    "mint" -> Color(0xFF31B99A)
    "teal" -> Color(0xFF159EAF)
    "cyan" -> Color(0xFF209BCC)
    "blue" -> Color(0xFF3979E9)
    "purple" -> Color(0xFF8B5CF6)
    "pink" -> Color(0xFFE35C9A)
    "brown" -> Color(0xFF9B6A4A)
    "gray" -> Color(0xFF7A7A85)
    "coral" -> Color(0xFFFA6161)
    "peach" -> Color(0xFFFF9461)
    "gold" -> Color(0xFFE6A314)
    "lime" -> Color(0xFF85C729)
    "forest" -> Color(0xFF1A7A4D)
    "turquoise" -> Color(0xFF0DABA1)
    "sky" -> Color(0xFF2E9EE8)
    "navy" -> Color(0xFF1F4085)
    "lavender" -> Color(0xFF8C66D9)
    "magenta" -> Color(0xFFD1298C)
    "slate" -> Color(0xFF4D5C73)
    else -> Color(0xFF5B5BD6)
}

fun iconFor(name: String): ImageVector = when (name) {
    "star", "star.fill" -> Icons.Default.Star
    "heart.fill", "health" -> Icons.Default.Favorite
    "sparkles" -> Icons.Default.AutoAwesome
    "bolt.fill" -> Icons.Default.Bolt
    "flame.fill" -> Icons.Default.LocalFireDepartment
    "drop.fill" -> Icons.Default.WaterDrop
    "cart", "cart.fill" -> Icons.Default.LocalGroceryStore
    "bag", "bag.fill" -> Icons.Default.ShoppingBag
    "creditcard.fill" -> Icons.Default.CreditCard
    "money", "banknote.fill" -> Icons.Default.AccountBalanceWallet
    "gift", "gift.fill" -> Icons.Default.CardGiftcard
    "tag.fill" -> Icons.Default.Sell
    "cup.and.saucer.fill" -> Icons.Default.Coffee
    "fork.knife" -> Icons.Default.Restaurant
    "takeoutbag.and.cup.and.straw.fill" -> Icons.Default.Fastfood
    "birthday.cake.fill" -> Icons.Default.Cake
    "car", "car.fill", "bus.fill", "tram.fill" -> Icons.Default.DirectionsCar
    "bicycle" -> Icons.Default.PedalBike
    "airplane" -> Icons.Default.Flight
    "fuelpump.fill" -> Icons.Default.LocalGasStation
    "home", "house.fill" -> Icons.Default.Home
    "bed.double.fill" -> Icons.Default.Bed
    "lightbulb.fill" -> Icons.Default.Lightbulb
    "wifi" -> Icons.Default.Wifi
    "phone.fill" -> Icons.Default.Phone
    "printer.fill" -> Icons.Default.Print
    "pawprint.fill" -> Icons.Default.Pets
    "leaf.fill" -> Icons.Default.Eco
    "figure.walk" -> Icons.AutoMirrored.Filled.DirectionsWalk
    "figure.run" -> Icons.AutoMirrored.Filled.DirectionsRun
    "dumbbell.fill" -> Icons.Default.FitnessCenter
    "cross.case.fill", "stethoscope" -> Icons.Default.MedicalServices
    "pills.fill" -> Icons.Default.Medication
    "book.fill" -> Icons.AutoMirrored.Filled.MenuBook
    "school", "graduationcap.fill" -> Icons.Default.School
    "laptopcomputer" -> Icons.Default.Laptop
    "briefcase.fill" -> Icons.Default.Work
    "gamecontroller.fill" -> Icons.Default.SportsEsports
    "music.note" -> Icons.Default.MusicNote
    "movie", "film.fill" -> Icons.Default.Movie
    "camera.fill" -> Icons.Default.CameraAlt
    "paintpalette.fill" -> Icons.Default.Palette
    "tshirt.fill" -> Icons.Default.Checkroom
    "hammer.fill", "wrench.and.screwdriver.fill" -> Icons.Default.Construction
    "shippingbox.fill" -> Icons.Default.Inventory2
    "globe.europe.africa.fill" -> Icons.Default.Public
    "chart", "chart.line.uptrend.xyaxis" -> Icons.Default.BarChart
    "tune" -> Icons.Default.Tune
    "plus.circle.fill" -> Icons.Default.Add
    "repeat", "ellipsis.circle.fill", "more" -> Icons.Default.MoreHoriz
    else -> Icons.Default.MoreHoriz
}

@Composable
fun CategoryBadge(category: CategoryDesign, modifier: Modifier = Modifier, size: Int = 42) {
    Box(
        modifier.size(size.dp).background(colorFor(category.colorName).copy(alpha = .16f), RoundedCornerShape(13.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (category.emoji.isNotBlank()) Text(category.emoji, fontSize = (size * .46f).sp)
        else Icon(iconFor(category.icon), null, tint = colorFor(category.colorName), modifier = Modifier.size((size * .48f).dp))
    }
}

@Composable
fun MetricCard(title: String, value: String, tint: Color, modifier: Modifier = Modifier) {
    Card(modifier, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = tint)
            Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, maxLines = 1)
        }
    }
}

@Composable
fun SpendingBars(items: List<CategoryTotal>, modifier: Modifier = Modifier) {
    if (items.isEmpty()) {
        Box(modifier.height(170.dp), contentAlignment = Alignment.Center) { Text("Нет расходов", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        return
    }
    val maximum = items.maxOf { it.amount }.coerceAtLeast(1.0)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        items.take(7).forEach { item ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(if (item.emoji.isBlank()) item.name else "${item.emoji} ${item.name}", Modifier.weight(1f), maxLines = 1)
                Text("%.0f%%".format(item.amount / items.sumOf { it.amount } * 100), style = MaterialTheme.typography.labelMedium)
            }
            Canvas(Modifier.fillMaxWidth().height(8.dp)) {
                drawRoundRect(Color.Gray.copy(alpha = .18f), cornerRadius = CornerRadius(size.height / 2))
                drawRoundRect(
                    colorFor(item.colorName),
                    size = Size(size.width * (item.amount / maximum).toFloat(), size.height),
                    cornerRadius = CornerRadius(size.height / 2),
                )
            }
        }
    }
}

fun periodBounds(months: Int, now: Long = System.currentTimeMillis()): Pair<Long, Long> {
    val zone = ZoneId.systemDefault()
    val date = Instant.ofEpochMilli(now).atZone(zone)
    val currentStart = date.withDayOfMonth(1).toLocalDate().atStartOfDay(zone)
    val start = currentStart.minusMonths((months - 1).toLong())
    val end = currentStart.plusMonths(1)
    return start.toInstant().toEpochMilli() to end.toInstant().toEpochMilli()
}

@Preview(name = "Metric Card", showBackground = true)
@Composable
fun MetricCardPreview() {
    BalanceTheme(theme = "dark") {
        MetricCard("Доходы", "120 000 ₽", BalanceGreen)
    }
}

@Preview(name = "Category Badge", showBackground = true)
@Composable
fun CategoryBadgePreview() {
    BalanceTheme(theme = "dark") {
        CategoryBadge(CategoryDesign("Продукты", "cart.fill", "🛒", "orange", "expense"))
    }
}

@Preview(name = "Spending Bars", showBackground = true)
@Composable
fun SpendingBarsPreview() {
    BalanceTheme(theme = "dark") {
        SpendingBars(
            listOf(
                CategoryTotal("Продукты", "cart.fill", "🛒", "orange", 12500.0),
                CategoryTotal("Кафе", "fork.knife", "☕", "indigo", 4200.0),
                CategoryTotal("Транспорт", "car.fill", "🚗", "purple", 3100.0),
            )
        )
    }
}

