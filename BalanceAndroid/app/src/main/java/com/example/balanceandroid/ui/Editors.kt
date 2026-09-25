package com.example.balanceandroid.ui

import android.app.DatePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.example.balanceandroid.FinanceUiState
import com.example.balanceandroid.MainViewModel
import com.example.balanceandroid.data.CategoryDesign
import com.example.balanceandroid.data.CategoryEntity
import com.example.balanceandroid.data.TransactionEntity
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun TransactionEditorDialog(
    model: MainViewModel,
//    state: FinanceUiState,
    existing: TransactionEntity?,
    onDismiss: () -> Unit,
) {
    var amount by remember(existing?.id) { mutableStateOf(existing?.amount?.toString().orEmpty()) }
    var kind by remember(existing?.id) { mutableStateOf(existing?.kindRawValue ?: "expense") }
    var note by remember(existing?.id) { mutableStateOf(existing?.note.orEmpty()) }
    var date by remember(existing?.id) { mutableLongStateOf(existing?.date ?: System.currentTimeMillis()) }
    val categories = model.categories(kind)
    var categoryName by remember(existing?.id) { mutableStateOf(existing?.categoryName ?: categories.first().name) }
    val selected = categories.firstOrNull { it.name == categoryName } ?: categories.first()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if(existing == null) "Новая операция" else "Редактирование") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(kind == "expense", { kind = "expense"; categoryName = model.categories("expense").first().name }, label = { Text("Расход") })
                    FilterChip(kind == "income", { kind = "income"; categoryName = model.categories("income").first().name }, label = { Text("Доход") })
                }
                OutlinedTextField(amount, { amount = it }, Modifier.fillMaxWidth(), label = { Text("Сумма") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true)
                DialogChoice("Категория", categoryName, categories.map { it.name }) { categoryName = it }
                DateChoice(date) { date = it }
                OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Заметка") })
            }
        },
        confirmButton = {
            Button({ model.saveTransaction(existing, amount.replace(',', '.').toDoubleOrNull() ?: 0.0, kind, selected, note, date); onDismiss() }, enabled = (amount.replace(',', '.').toDoubleOrNull() ?: 0.0) > 0) { Text("Сохранить") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Отмена") } },
    )
}

@Composable
fun CategoryEditorDialog(
    model: MainViewModel,
    state: FinanceUiState,
    existing: CategoryEntity?,
    onDismiss: () -> Unit,
) {
    var name by remember(existing?.id) { mutableStateOf(existing?.name.orEmpty()) }
    var kind by remember(existing?.id) { mutableStateOf(existing?.kindRawValue ?: "expense") }
    var icon by remember(existing?.id) { mutableStateOf(existing?.icon ?: "star") }
    var emoji by remember(existing?.id) { mutableStateOf(existing?.emoji.orEmpty()) }
    var color by remember(existing?.id) { mutableStateOf(existing?.colorName ?: "indigo") }
    var useEmoji by remember(existing?.id) { mutableStateOf(existing?.emoji?.isNotBlank() == true) }
    val duplicate = state.data.categories.any { it.id != existing?.id && it.kindRawValue == kind && it.name.equals(name.trim(), true) }
    val icons = listOf(
        "star.fill", "heart.fill", "sparkles", "bolt.fill", "flame.fill", "drop.fill",
        "cart.fill", "bag.fill", "creditcard.fill", "banknote.fill", "gift.fill", "tag.fill",
        "cup.and.saucer.fill", "fork.knife", "takeoutbag.and.cup.and.straw.fill", "birthday.cake.fill",
        "car.fill", "bus.fill", "tram.fill", "bicycle", "airplane", "fuelpump.fill",
        "house.fill", "bed.double.fill", "lightbulb.fill", "wifi", "phone.fill", "printer.fill",
        "pawprint.fill", "leaf.fill", "figure.walk", "figure.run", "dumbbell.fill", "cross.case.fill",
        "pills.fill", "stethoscope", "book.fill", "graduationcap.fill", "laptopcomputer", "briefcase.fill",
        "gamecontroller.fill", "music.note", "film.fill", "camera.fill", "paintpalette.fill", "tshirt.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "shippingbox.fill", "globe.europe.africa.fill",
    )
    val emojis = listOf(
        "🍔", "☕️", "🛒", "🚕", "✈️", "🏠", "💡", "📱", "💻", "🎮",
        "🎬", "🎵", "📚", "🎓", "💊", "🏋️", "🐶", "🐱", "👕", "🎁",
        "💰", "💳", "📈", "🔧", "🌿", "❤️", "⭐️", "🎯", "🧾", "🏖️",
    )
    val colors = listOf(
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue",
        "indigo", "purple", "pink", "gray", "coral", "peach", "gold", "lime",
        "forest", "turquoise", "sky", "navy", "lavender", "magenta", "brown", "slate",
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if(existing == null) "Новая категория" else "Редактирование") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Название") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(kind == "expense", { if(existing == null) kind = "expense" }, label = { Text("Расход") })
                    FilterChip(kind == "income", { if(existing == null) kind = "income" }, label = { Text("Доход") })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(!useEmoji, { useEmoji = false }, label = { Text("Иконка") })
                    FilterChip(useEmoji, { useEmoji = true }, label = { Text("Эмодзи") })
                }
                if (useEmoji) {
                    OutlinedTextField(emoji, { emoji = it }, Modifier.fillMaxWidth(), label = { Text("Эмодзи") }, singleLine = true)
                    EmojiChoice(emoji, emojis) { emoji = it }
                } else IconChoice(icon, color, kind, icons) { icon = it }
                ColorChoice(color, colors) { color = it }
                if (duplicate) Text("Категория с таким названием уже существует", color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            Button({ model.saveCategory(existing, name, kind, icon, if(useEmoji) emoji.trim() else "", color); onDismiss() }, enabled = name.isNotBlank() && !duplicate && (!useEmoji || emoji.isNotBlank())) { Text("Сохранить") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Отмена") } },
    )
}

@Composable
private fun IconChoice(current: String, color: String, kind: String, values: List<String>, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text("Иконка", style = MaterialTheme.typography.labelLarge)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(values, key = { it }) { value ->
                Box(
                    Modifier
                        .border(if (value == current) 2.dp else 0.dp, MaterialTheme.colorScheme.primary, CircleShape)
                        .padding(3.dp)
                        .clickable { onSelect(value) }
                ) {
                    CategoryBadge(CategoryDesign("", value, "", color, kind), size = 40)
                }
            }
        }
    }
}

@Composable
private fun EmojiChoice(current: String, values: List<String>, onSelect: (String) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(values, key = { it }) { value ->
            Box(
                Modifier
                    .size(44.dp)
                    .border(if (value == current) 2.dp else 1.dp, if (value == current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant, CircleShape)
                    .clickable { onSelect(value) },
                contentAlignment = Alignment.Center,
            ) { Text(value) }
        }
    }
}

@Composable
private fun ColorChoice(current: String, values: List<String>, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text("Цвет", style = MaterialTheme.typography.labelLarge)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            items(values, key = { it }) { value ->
                Box(
                    Modifier
                        .size(34.dp)
                        .border(if (value == current) 3.dp else 1.dp, if (value == current) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outlineVariant, CircleShape)
                        .padding(4.dp)
                        .background(colorFor(value), CircleShape)
                        .clickable { onSelect(value) }
                )
            }
        }
    }
}

@Composable
fun BudgetEditorDialog(model: MainViewModel, state: FinanceUiState, onDismiss: () -> Unit) {
    val categories = model.categories("expense")
    val month = MainViewModel.currentMonthStart()
    val limits = remember(state.data.budgets) { mutableStateMapOf<String, String>().apply {
        categories.forEach { category ->
            put(category.name, state.data.budgets.firstOrNull { it.categoryName == category.name && it.monthStart == month }?.limitAmount?.toString().orEmpty())
        }
    } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Месячные лимиты") },
        text = {
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                categories.forEach { category ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CategoryBadge(category, size = 34); Spacer(Modifier.size(9.dp)); Text(category.name, Modifier.weight(1f), maxLines = 1)
                        OutlinedTextField(limits[category.name].orEmpty(), { limits[category.name] = it }, Modifier.fillMaxWidth(.38f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true)
                    }
                }
            }
        },
        confirmButton = { Button({ categories.forEach { model.saveBudget(it, limits[it.name].orEmpty().replace(',', '.').toDoubleOrNull() ?: 0.0, month) }; onDismiss() }) { Text("Сохранить") } },
        dismissButton = { TextButton(onDismiss) { Text("Отмена") } },
    )
}

@Composable
fun BalanceAdjustmentDialog(current: Double, currency: String, onDismiss: () -> Unit, onSave: (Double, String) -> Unit) {
    var target by remember { mutableStateOf(current.toString()) }
    var note by remember { mutableStateOf("") }
    val value = target.replace(',', '.').toDoubleOrNull()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Корректировка баланса") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Расчётный баланс: ${formatMoney(current, currency)}")
            OutlinedTextField(target, { target = it }, Modifier.fillMaxWidth(), label = { Text("Фактический баланс") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true)
            OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Комментарий") })
            Text("Корректировка не влияет на аналитику.", style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { Button({ value?.let { onSave(it, note) } }, enabled = value != null && kotlin.math.abs(value - current) >= .005) { Text("Сохранить") } },
        dismissButton = { TextButton(onDismiss) { Text("Отмена") } },
    )
}

@Composable
private fun DialogChoice(title: String, current: String, values: List<String>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton({ expanded = true }, Modifier.fillMaxWidth()) { Text("$title: ${current.ifBlank { "Выбрать" }}", Modifier.weight(1f)) }
        DropdownMenu(expanded, { expanded = false }) {
            values.forEach { value -> DropdownMenuItem({ Text(value) }, { onSelect(value); expanded = false }) }
        }
    }
}

@Composable
private fun DateChoice(value: Long, onChange: (Long) -> Unit) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    val date = Instant.ofEpochMilli(value).atZone(zone).toLocalDate()
    OutlinedButton({
        DatePickerDialog(context, { _, year, month, day ->
            onChange(LocalDate.of(year, month + 1, day).atStartOfDay(zone).toInstant().toEpochMilli())
        }, date.year, date.monthValue - 1, date.dayOfMonth).show()
    }, Modifier.fillMaxWidth()) {
        Text("Дата: ${date.format(DateTimeFormatter.ofPattern("d MMMM yyyy"))}")
    }
}
